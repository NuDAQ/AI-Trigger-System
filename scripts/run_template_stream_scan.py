#!/usr/bin/env python3
"""Scan complete single-channel template streams using the existing XSim bench."""
from collections import Counter, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
import argparse
import csv
import json
from pathlib import Path
import re
from queue import Queue
import shutil
import struct
import subprocess
import sys

try:
    from . import run_real_noise_scan as scope
except ImportError:
    import run_real_noise_scan as scope


def native_code(word: str) -> int:
    value = int(word, 16) & 0x1FFFFF
    return value - 0x200000 if value & 0x100000 else value


class NativeReference:
    """Independent generated HLS reference, with a cache of exact raw windows."""
    def __init__(self, binary: Path, output: Path):
        self.output = output
        output.mkdir(parents=True)
        self.binary = output / "native_reference"
        shutil.copy2(binary, self.binary)
        shutil.copytree(binary.parent / "weights", output / "weights")
        self.cache = {}

    def scores(self, windows: list[list[int]]) -> list[int]:
        import numpy as np
        keys = [struct.pack("<256h", *window) for window in windows]
        missing = {key: window for key, window in zip(keys, windows) if key not in self.cache}
        if missing:
            features = np.zeros((len(missing), 256, 4), dtype="<f4")
            features[:, :, 0] = np.asarray(list(missing.values()), dtype=np.float32) * 6 / 64
            features.tofile(self.output / "features.f32")
            with (self.output / "csim.log").open("w") as log:
                subprocess.run([str(self.binary.resolve()), str(len(missing))], cwd=self.output,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            words = (self.output / "all_expected.hex").read_text().splitlines()
            if len(words) != len(missing):
                raise SystemExit("native reference did not produce every requested window")
            with (self.output.parent / "hls_reference_windows.jsonl").open("a") as log:
                for key, raw, word in zip(missing, missing.values(), words):
                    self.cache[key] = native_code(word)
                    log.write(json.dumps({"raw_ch0": raw, "score_code": self.cache[key]}) + "\n")
        return [self.cache[key] for key in keys]


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
    if mode == 2 and (len(scores) != len(codes) // 256 or
                      {int(row["sample_id"]) for row in scores} != set(range(len(codes) // 256))):
        raise SystemExit(f"incomplete continuous scores: {case_dir}")
    source_origin = int(scope.read_csv_rows(case_dir / "manifest.csv")[0]["window_start_index"])
    log = (case_dir / "simulate.log").read_text()
    received = re.search(r"^Results received:\s+(\d+)", log, re.MULTILINE)
    if not received or int(received.group(1)) != len(scores):
        raise SystemExit(f"score rows differ from simulator results: {case_dir}")
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
    saved = re.search(r"^Events saved:\s+(\d+)", log, re.MULTILINE)
    if not saved or int(saved.group(1)) != len(groups):
        raise SystemExit(f"event frames differ from simulator results: {case_dir}")
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


def run_snapshot(snapshot_dir: Path, output: Path, config: dict, xsim: Path) -> None:
    """Replay the already compiled bench in a new process with fresh reset state."""
    output.mkdir(parents=True)
    prepared = Path(config["input_dir"])
    shutil.copy2(prepared / "manifest.csv", output / "manifest.csv")
    (output / "testhex_stream").symlink_to(prepared / "testhex_stream", target_is_directory=True)
    tcl = output / "run_all.tcl"
    tcl.write_text("run all\nquit\n")
    values = {"TESTHEX_DIR": prepared / "testhex_stream", "OUT_CSV": output / "scores.csv",
              "EVENT_CSV": output / "events.csv", "NUM_SAMPLES": len(scope.read_csv_rows(prepared / "manifest.csv")),
              "SCORE_THRESHOLD": config["threshold_raw"] / 16, "CNN_THRESH_RAW": config["threshold_raw"],
              "MIRROR_RAW_CHANNELS": 0, "TRIGGER_MODE": config["mode"], "FORCE_TRIGGER_INTERVAL": 0,
              "HL_THRESH": config["hl_threshold_raw"], "HILO_WINDOW": config["hilo_window"],
              "COINC_WINDOW": 3, "BIN_THR": 1}
    command = [str(xsim), "tb_AI_TRIGGER_TOP_behav", "-tclbatch", str(tcl), "-log", str(output / "simulate.log")]
    for key, value in values.items():
        command += ["-testplusarg", f"{key}={value}"]
    (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (output / "console.log").open("w") as log:
        subprocess.run(command, cwd=snapshot_dir, stdout=log, stderr=subprocess.STDOUT, check=True)
    try:
        from .run_vivado_sim import validate_simulation_log
    except ImportError:
        from run_vivado_sim import validate_simulation_log
    validate_simulation_log(output / "simulate.log")


def check_native_reference(case_dir: Path, result: dict, reference: NativeReference) -> None:
    codes = load_stream_codes(case_dir)
    with (case_dir / "scores.csv").open() as stream:
        rows = list(csv.DictReader(stream))
    exact = 0
    if result["mode"] == 2:
        starts = [int(row["sample_id"]) * 256 for row in rows]
        expected = reference.scores([codes[start:start + 256] for start in starts])
        if expected != [native_code(row["hex_out"]) for row in rows]:
            raise SystemExit(f"continuous native reference mismatch: {case_dir}")
        exact = len(rows)
    elif result["mode"] == 4:
        expected = reference.scores([codes[e["stream_start_index"]:e["stream_start_index"] + 256]
                                     for e in result["events"]])
        if expected != [e["score_code"] for e in result["events"]]:
            raise SystemExit(f"centered native reference mismatch: {case_dir}")
        exact = len(expected)
    # The public score CSV carries the start chunk but no gated beat offset.
    # Rejected work can be checked against possible windows, without inventing
    # an exact location when equal quantized scores leave it ambiguous.
    rejected = []
    if result["mode"] == 4:
        for row in rows:
            if native_code(row["hex_out"]) > result["threshold_raw"] * 32:
                continue
            starts = [int(row["sample_id"]) * 256 + offset * 4 for offset in range(64)]
            starts = [start for start in starts if 0 <= start and start + 256 <= len(codes)]
            expected = reference.scores([codes[start:start + 256] for start in starts])
            matching = [start for start, value in zip(starts, expected) if value == native_code(row["hex_out"])]
            if not matching:
                raise SystemExit(f"rejected gated score has no matching native input window: {case_dir}")
            rejected.append({"start_chunk": int(row["sample_id"]), "score_code": native_code(row["hex_out"]),
                             "possible_stream_start_indices": matching})
        (case_dir / "rejected_score_matches.json").write_text(json.dumps(rejected, indent=2) + "\n")
    result.update(exact_reference_scores=exact, rejected_reference_scores=len(rejected),
                  rejected_reference_ambiguous=sum(len(r["possible_stream_start_indices"]) > 1 for r in rejected))
    (case_dir / "stream_summary.json").write_text(json.dumps(result, indent=2) + "\n")


def execute_plan(args, plan: dict) -> int:
    root = Path(__file__).resolve().parents[1]
    output = args.out_dir.resolve()
    snapshot = args.snapshot_dir.resolve()
    source_manifest = snapshot.parents[4] / "source_manifest.json"
    compiled = json.loads(source_manifest.read_text())
    for item in compiled["files"]:
        if item["package"] == "ai-trigger-system":
            matches = list((root / "HDL").rglob(item["file"]))
            if len(matches) != 1 or scope.sha256(matches[0]) != item["sha256"]:
                raise SystemExit(f"compiled system source differs from checkout: {item['file']}")
    shutil.copy2(source_manifest, output / "compiled_source_manifest.json")
    reference_metadata = args.reference_engine.parent / "reference.json"
    metadata = json.loads(reference_metadata.read_text())
    if metadata["harness_sha256"] != scope.sha256(root / "scripts/native_reference.cpp"):
        raise SystemExit("reference engine harness differs from current checkout")
    shutil.copy2(reference_metadata, output / "native_reference_manifest.json")
    provenance = {"ai_trigger_commit": scope.git_value(root, "rev-parse", "HEAD"),
                  "script_sha256": scope.sha256(Path(__file__)), "scope_script_sha256": scope.sha256(root / "scripts/run_real_noise_scan.py"),
                  "reference_binary_sha256": scope.sha256(args.reference_engine), "snapshot_dir": str(snapshot),
                  "compiled_source_manifest_sha256": scope.sha256(source_manifest), "xsim": str(args.xsim),
                  "cnn_input_gain": 6, "adc_vfs_v": .8, "workers": args.workers}
    source_snapshot = root / "source_snapshot.json"
    if source_snapshot.exists():
        shutil.copy2(source_snapshot, output / "source_snapshot.json")
        if provenance["ai_trigger_commit"] == "unknown":
            provenance["ai_trigger_commit"] = json.loads(source_snapshot.read_text())["root_commit"]
    (output / "scan_provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    reference = NativeReference(args.reference_engine, output / "reference_engine")
    workers = Queue()
    for index in range(args.workers):
        worker = output / f"xsim_worker_{index}"
        shutil.copytree(snapshot, worker, symlinks=True, ignore=shutil.ignore_patterns("*.wdb", "*.log", "*.jou"))
        workers.put(worker)
    cases = plan["cases"][:args.limit] if args.limit else plan["cases"]
    fields = ["template", "variant", "phase", "mode", "hl_threshold_raw", "hilo_window", "threshold_raw",
              "cnn_evaluations", "raw_events_checked", "score_max", "exact_reference_scores",
              "rejected_reference_scores", "rejected_reference_ambiguous", "dropped_triggers", "event_loss", "hilo_blanking"]
    summaries = []

    def run_case(config):
        tag = f"p{config['phase']:03d}_m{config['mode']}_h{config['hl_threshold_raw']}_w{config['hilo_window']}_t{config['threshold_raw']}"
        case_dir = output / "runs" / f"{config['template']}_{config['variant']}" / tag
        worker = workers.get()
        try:
            run_snapshot(worker, case_dir, config, args.xsim)
        finally:
            workers.put(worker)
        return case_dir

    def status(complete=False, passed=True, error=None):
        (output / "summary.json").write_text(json.dumps({"complete": complete, "passed": passed,
            "scenarios_planned": len(cases), "scenarios_completed": len(summaries), "error": error,
            "exact_reference_scores": sum(r["exact_reference_scores"] for r in summaries),
            "raw_events_checked": sum(r["raw_events_checked"] for r in summaries),
            "rejected_reference_scores": sum(r["rejected_reference_scores"] for r in summaries),
            "rejected_reference_ambiguous": sum(r["rejected_reference_ambiguous"] for r in summaries)}, indent=2) + "\n")
    status()
    pool = ThreadPoolExecutor(max_workers=args.workers)
    pending = deque((i, pool.submit(run_case, cases[i])) for i in range(min(args.workers, len(cases))))
    next_index = len(pending)
    try:
        with (output / "scan_summary.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            while pending:
                index, future = pending.popleft()
                config = cases[index]
                case_dir = future.result()
                result = analyze_stream(case_dir, mode=config["mode"], threshold_raw=config["threshold_raw"])
                check_native_reference(case_dir, result, reference)
                row = {key: config.get(key, result.get(key)) for key in fields}
                row.update(dropped_triggers=result["health"]["Dropped triggers"],
                           event_loss=result["health"]["Event loss"], hilo_blanking=result["health"]["Hi-Lo blanking"])
                writer.writerow(row)
                stream.flush()
                summaries.append(row)
                status()
                print(f"PASS {index + 1}/{len(cases)} {config['template']} {config['variant']} phase={config['phase']} "
                      f"mode={config['mode']} HL={config['hl_threshold_raw']} window={config['hilo_window']} "
                      f"CNN={result['cnn_evaluations']} events={result['raw_events_checked']}", flush=True)
                if next_index < len(cases):
                    pending.append((next_index, pool.submit(run_case, cases[next_index])))
                    next_index += 1
        status(complete=True)
    except BaseException as error:
        status(passed=False, error=str(error))
        for _, future in pending:
            future.cancel()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=Path("build/template_stream_scan"))
    parser.add_argument("--case", action="append")
    parser.add_argument("--variants", nargs="+", choices=("noisy", "noiseless", "noise"),
                        default=["noisy", "noiseless", "noise"])
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--phase-scan", action="store_true")
    parser.add_argument("--hilo-scan", action="store_true")
    parser.add_argument("--snapshot-dir", type=Path, help="XSim directory from a qualified isolated native simulation.")
    parser.add_argument("--reference-engine", type=Path, help="Qualified native_reference executable beside its weights and manifest.")
    parser.add_argument("--xsim", type=Path, default=Path("/tools/Xilinx/Vivado/2023.2/bin/xsim"))
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=1)
    parser.add_argument("--limit", type=int, default=0, help="Run only the first N cases for a smoke check.")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be nonnegative")
    if not args.prepare_only and (not args.snapshot_dir or not args.reference_engine):
        parser.error("simulation needs --snapshot-dir and --reference-engine")
    if args.out_dir.exists() and any(args.out_dir.iterdir()):
        parser.error("--out-dir must be empty so previous results are preserved")
    plan = prepare_plan(args)
    print(f"Prepared {len(plan['cases'])} stream scenarios")
    if args.prepare_only:
        return 0
    return execute_plan(args, plan)


if __name__ == "__main__":
    sys.exit(main())
