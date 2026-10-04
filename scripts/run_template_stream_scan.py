#!/usr/bin/env python3
"""Scan complete single-channel template streams using the existing XSim bench."""
from collections import Counter, defaultdict
import argparse
import csv
import json
from pathlib import Path
import re
import sys

try:
    from . import run_real_noise_scan as scope
except ImportError:
    import run_real_noise_scan as scope


def native_code(word: str) -> int:
    value = int(word, 16) & 0x1FFFFF
    return value - 0x200000 if value & 0x100000 else value


def load_stream_codes(case_dir: Path) -> list[int]:
    codes = []
    for row in scope.read_csv_rows(case_dir / "manifest.csv"):
        path = case_dir / "testhex_stream" / f"test_input_sample{row['sample_id']}.hex"
        for word in path.read_text().splitlines():
            raw = int(word, 16) & 0xFFF
            codes.append(raw - 4096 if raw & 2048 else raw)
    return codes


def analyze_stream(case_dir: Path, *, mode: int, threshold_raw: int) -> dict:
    """Validate centered event framing and every raw ADC sample before reporting."""
    with (case_dir / "scores.csv").open() as f:
        scores = list(csv.DictReader(f))
    with (case_dir / "events.csv").open() as f:
        event_rows = list(csv.DictReader(f))
    codes = load_stream_codes(case_dir)
    source_origin = int(scope.read_csv_rows(case_dir / "manifest.csv")[0]["window_start_index"])
    log = (case_dir / "simulate.log").read_text()
    health = {}
    for name in ("Chunk overflows", "ADC input overflows", "Dropped triggers", "Ring misses",
                 "Hi-Lo blanking", "Event loss"):
        match = re.search(rf"^{re.escape(name)}:\s+(\d+)", log, re.MULTILINE)
        if not match:
            raise SystemExit(f"missing {name} counter: {case_dir}")
        health[name] = int(match.group(1))
    if any(health[name] for name in ("Chunk overflows", "ADC input overflows", "Ring misses")):
        raise SystemExit(f"stream health failure: {health}")
    groups = defaultdict(list)
    for row in event_rows:
        groups[int(row["event_index"])].append(row)
    events = []
    for event_index, rows in sorted(groups.items()):
        first = rows[0]
        start = int(first["event_chunk_id"]) * 256
        if mode in (3, 4):
            start = int(first["event_timestamp"]) * 256 + int(first["event_trigger_offset"]) * 4 - 124
        if len(rows) != 64 or start < 0 or start + 256 > len(codes):
            raise SystemExit(f"incomplete or out-of-range event {event_index}: {case_dir}")
        for beat, row in enumerate(rows):
            if int(row["event_batch_index"]) != beat or int(row["event_last"]) != int(beat == 63):
                raise SystemExit(f"event framing mismatch: {case_dir}")
            if any(row[key] != first[key] for key in
                   ("event_chunk_id", "event_timestamp", "event_trigger_offset", "event_score_hex")):
                raise SystemExit(f"event metadata changed within a frame: {case_dir}")
            expected = sum((raw & 0xFFF) << (12 * i)
                           for i, raw in enumerate(codes[start + beat * 4:start + beat * 4 + 4]))
            if int(row["event_data_hex"], 16) != expected:
                raise SystemExit(f"raw waveform mismatch event={event_index} beat={beat}: {case_dir}")
        if mode in (2, 4) and native_code(first["event_score_hex"]) <= threshold_raw * 32:
            raise SystemExit(f"nonqualifying score produced an event: {case_dir}")
        if mode == 3 and native_code(first["event_score_hex"]) != 0:
            raise SystemExit(f"Hi-Lo-only event has a CNN score: {case_dir}")
        events.append({"event_index": event_index, "stream_start_index": start,
                       "source_start_index": start + source_origin,
                       "score_code": native_code(first["event_score_hex"]),
                       "score": native_code(first["event_score_hex"]) / 512})
    actual = Counter((int(row["sample_id"]), native_code(row["hex_out"])) for row in scores)
    expected = Counter((event["stream_start_index"] // 256, event["score_code"]) for event in events)
    qualifying = Counter({key: count for key, count in actual.items() if key[1] > threshold_raw * 32})
    if mode in (2, 4) and qualifying != expected:
        raise SystemExit(f"qualifying CNN scores and complete events differ: {case_dir}")
    if mode == 3 and scores:
        raise SystemExit(f"Hi-Lo-only mode performed CNN work: {case_dir}")
    result = {"mode": mode, "threshold_raw": threshold_raw, "cnn_evaluations": len(scores),
              "raw_events_checked": len(events), "events": events, "health": health,
              "score_max": max((native_code(row["hex_out"]) / 512 for row in scores), default=None)}
    (case_dir / "stream_summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def prepare_plan(args) -> dict:
    root = Path(__file__).resolve().parents[1]
    dataset = root / scope.TEMPLATE_RELATIVE_DIR
    templates = [row["template"] for row in scope.read_csv_rows(dataset / "manifest_examples.csv")]
    selected = args.case or templates
    if len(set(selected)) != len(selected) or set(selected) - set(templates):
        raise SystemExit("select unique template names from manifest_examples.csv")
    output = args.out_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases, seen, inputs = [], set(), {}

    def add(template, variant, phase, mode, hl=35, hilo=5, threshold=45):
        key = (template, variant, phase, mode, hl, hilo, threshold)
        if key in seen:
            return
        seen.add(key)
        input_key = (template, variant, phase)
        if input_key not in inputs:
            source = dataset / f"{template}_{variant}.csv"
            if variant == "noise":
                source = output / "input_sources" / f"{template}_noise.csv"
                source.parent.mkdir(exist_ok=True)
                times, noisy = scope.load_scope_csv(dataset / f"{template}_noisy.csv")
                _, noiseless = scope.load_scope_csv(dataset / f"{template}_noiseless.csv")
                source.write_text("x-axis,1\nsecond,Volt\n" + "\n".join(
                    f"{t:.12e},{a - b:.12e}" for t, a, b in zip(times, noisy, noiseless)) + "\n")
            prepared = scope.prepare_scope_csv(source, output / "inputs" / f"p{phase:03d}", .8,
                                               schedule="stream", pad_before=256 + phase)
            inputs[input_key] = str(prepared)
        cases.append({"template": template, "variant": variant, "phase": phase, "mode": mode,
                      "hl_threshold_raw": hl, "hilo_window": hilo, "threshold_raw": threshold,
                      "input_dir": inputs[input_key]})

    for template in selected:
        for variant in args.variants:
            add(template, variant, 0, 2)
            add(template, variant, 0, 3)
            add(template, variant, 0, 4, threshold=-2147483648)
            add(template, variant, 0, 4)
        if args.phase_scan:
            for phase in range(256):
                add(template, "noisy", phase, 2)
            for phase in range(16):
                add(template, "noisy", phase, 3)
                add(template, "noisy", phase, 4, threshold=-2147483648)
                add(template, "noisy", phase, 4)
        if args.hilo_scan:
            for hl in (20, 25, 30, 35, 40):
                for hilo in (2, 4, 5, 8, 16):
                    add(template, "noisy", 0, 3, hl, hilo)
                    add(template, "noisy", 0, 4, hl, hilo, -2147483648)
                    add(template, "noisy", 0, 4, hl, hilo)
    plan = {"dataset": str(dataset), "adc_vfs_v": .8, "cnn_input_gain": 6,
            "bin_threshold": 1, "coincidence_window": 3, "cases": cases,
            "input_hashes": {p.name: scope.sha256(p) for p in sorted(dataset.iterdir()) if p.is_file()}}
    (output / "run_plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=Path("build/template_stream_scan"))
    parser.add_argument("--case", action="append")
    parser.add_argument("--variants", nargs="+", choices=("noisy", "noiseless", "noise"),
                        default=["noisy", "noiseless", "noise"])
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--phase-scan", action="store_true")
    parser.add_argument("--hilo-scan", action="store_true")
    args = parser.parse_args()
    plan = prepare_plan(args)
    print(f"Prepared {len(plan['cases'])} stream scenarios")
    if not args.prepare_only:
        raise SystemExit("use --prepare-only until an XSim snapshot is supplied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
