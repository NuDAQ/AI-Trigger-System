#!/usr/bin/env python3
"""Prepare and run the NSF Jul 27 continuous-trigger Vivado simulation."""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np


N_TRIGGER_CHANNELS = 4
SAMPLES_PER_CHUNK = 256
MODEL_INPUT_SCALE = 64.0
N_ADC_CHANNELS = 8
SAMPLES_PER_BEAT = 4
BEATS_PER_CHUNK = SAMPLES_PER_CHUNK // SAMPLES_PER_BEAT


def load_inputs(x_path: Path, labels_path: Path) -> tuple[np.ndarray, np.ndarray]:
    waveforms = np.asarray(np.load(x_path))
    labels = np.asarray(np.load(labels_path)).reshape(-1)

    if waveforms.ndim == 4 and waveforms.shape[-1] == 1:
        waveforms = waveforms[..., 0]
    expected_tail = (N_TRIGGER_CHANNELS, SAMPLES_PER_CHUNK)
    if waveforms.ndim != 3 or tuple(waveforms.shape[1:]) != expected_tail:
        raise SystemExit(
            f"expected waveform shape (N, 4, 256) or (N, 4, 256, 1), got {waveforms.shape}"
        )
    if len(labels) != len(waveforms):
        raise SystemExit(
            f"waveform/label count mismatch: {len(waveforms)} waveforms, {len(labels)} labels"
        )

    rounded_labels = np.rint(labels).astype(np.int64)
    if not np.all((rounded_labels == 0) | (rounded_labels == 1)):
        raise SystemExit("labels must contain only binary values 0 or 1")
    return waveforms, rounded_labels


def quantize_waveforms(waveforms: np.ndarray) -> np.ndarray:
    codes = np.rint(waveforms * MODEL_INPUT_SCALE).astype(np.int64)
    if np.any(codes < -2048) or np.any(codes > 2047):
        min_code = int(codes.min())
        max_code = int(codes.max())
        raise SystemExit(
            f"quantized waveform exceeds signed 12-bit range: min={min_code}, max={max_code}"
        )
    return codes


def pack_timestep(channel_codes: np.ndarray) -> str:
    word = 0
    for channel, code in enumerate(channel_codes):
        word |= (int(code) & 0xFFF) << (channel * 12)
    return f"{word:016x}"


def prepare_stimulus(
    x_path: Path,
    labels_path: Path,
    out_dir: Path,
    source_chunk_base: int,
) -> Path:
    waveforms, labels = load_inputs(x_path, labels_path)
    codes = quantize_waveforms(waveforms)

    testhex_dir = out_dir / "testhex_stream"
    testhex_dir.mkdir(parents=True, exist_ok=True)

    for local_chunk_id, chunk in enumerate(codes):
        lines = [
            pack_timestep(chunk[:, sample_index])
            for sample_index in range(SAMPLES_PER_CHUNK)
        ]
        (testhex_dir / f"test_input_sample{local_chunk_id}.hex").write_text(
            "\n".join(lines) + "\n",
            encoding="utf-8",
        )

    (testhex_dir / "labels.hex").write_text(
        "\n".join(str(int(label)) for label in labels) + "\n",
        encoding="utf-8",
    )

    with (out_dir / "manifest.csv").open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=["local_chunk_id", "source_chunk_id", "label"],
        )
        writer.writeheader()
        for local_chunk_id, label in enumerate(labels):
            writer.writerow(
                {
                    "local_chunk_id": local_chunk_id,
                    "source_chunk_id": source_chunk_base + local_chunk_id,
                    "label": int(label),
                }
            )

    print(f"Prepared {len(labels)} chunks in {testhex_dir}")
    return testhex_dir


def signed_bits(value: int, width: int) -> int:
    sign_bit = 1 << (width - 1)
    return value - (1 << width) if value & sign_bit else value


def read_manifest(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if not rows:
        raise SystemExit(f"manifest has no rows: {path}")
    return rows


def read_csv_by_int_key(path: Path, key: str) -> dict[int, dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    result: dict[int, dict[str, str]] = {}
    for row in rows:
        value = int(row[key])
        if value in result:
            raise SystemExit(f"duplicate {key}={value} in {path}")
        result[value] = row
    return result


def read_event_csv(path: Path) -> dict[int, dict[int, dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    events: dict[int, dict[int, dict[str, str]]] = {}
    for row in rows:
        chunk_id = int(row["event_chunk_id"])
        batch_index = int(row["event_batch_index"])
        chunk = events.setdefault(chunk_id, {})
        if batch_index in chunk:
            raise SystemExit(
                f"duplicate event chunk={chunk_id} batch={batch_index} in {path}"
            )
        chunk[batch_index] = row
    return events


def parse_log_counter(log_text: str, label: str) -> int:
    match = re.search(rf"^{re.escape(label)}:\s+(\d+)", log_text, re.MULTILINE)
    if not match:
        raise SystemExit(f"missing '{label}' counter in simulation log")
    return int(match.group(1))


def load_health_counters(path: Path) -> dict[str, int]:
    log_text = path.read_text(encoding="utf-8", errors="replace")
    return {
        "chunk_overflow_count": parse_log_counter(log_text, "Chunk overflows"),
        "adc_input_overflow_count": parse_log_counter(
            log_text, "ADC input overflows"
        ),
        "dropped_trigger_count": parse_log_counter(log_text, "Dropped triggers"),
        "ring_miss_count": parse_log_counter(log_text, "Ring misses"),
    }


def unpack_input_chunk(path: Path, mirror_raw_channels: int) -> list[list[list[int]]]:
    words = [int(line, 16) for line in path.read_text(encoding="utf-8").splitlines()]
    if len(words) != SAMPLES_PER_CHUNK:
        raise SystemExit(f"expected 256 testhex words in {path}, got {len(words)}")

    batches: list[list[list[int]]] = []
    for batch_index in range(BEATS_PER_CHUNK):
        batch = [[0 for _ in range(SAMPLES_PER_BEAT)] for _ in range(N_ADC_CHANNELS)]
        for sample_in_beat in range(SAMPLES_PER_BEAT):
            word = words[batch_index * SAMPLES_PER_BEAT + sample_in_beat]
            for channel in range(N_TRIGGER_CHANNELS):
                raw = (word >> (channel * 12)) & 0xFFF
                batch[channel][sample_in_beat] = signed_bits(raw, 12)
            if mirror_raw_channels:
                for channel in range(N_TRIGGER_CHANNELS, N_ADC_CHANNELS):
                    batch[channel][sample_in_beat] = batch[
                        channel % N_TRIGGER_CHANNELS
                    ][sample_in_beat]
        batches.append(batch)
    return batches


def unpack_event_batch(value: str) -> list[list[int]]:
    packed = int(value, 0)
    batch = [[0 for _ in range(SAMPLES_PER_BEAT)] for _ in range(N_ADC_CHANNELS)]
    for channel in range(N_ADC_CHANNELS):
        for sample_in_beat in range(SAMPLES_PER_BEAT):
            shift = (channel * SAMPLES_PER_BEAT + sample_in_beat) * 12
            batch[channel][sample_in_beat] = signed_bits((packed >> shift) & 0xFFF, 12)
    return batch


def waveform_columns(prefix: str) -> list[str]:
    return [
        f"{prefix}_ch{channel}_s{sample}"
        for channel in range(N_ADC_CHANNELS)
        for sample in range(SAMPLES_PER_BEAT)
    ]


def add_waveform(row: dict[str, object], prefix: str, batch: list[list[int]]) -> None:
    for channel in range(N_ADC_CHANNELS):
        for sample in range(SAMPLES_PER_BEAT):
            row[f"{prefix}_ch{channel}_s{sample}"] = batch[channel][sample]


def build_report(
    out_dir: Path,
    scores_path: Path,
    events_path: Path,
    log_path: Path,
    report_path: Path,
    cnn_thresh_raw: int,
    mirror_raw_channels: int,
) -> Path:
    manifest = read_manifest(out_dir / "manifest.csv")
    scores = read_csv_by_int_key(scores_path, "sample_id")
    events = read_event_csv(events_path)
    health = load_health_counters(log_path)
    health_ok = all(value == 0 for value in health.values())
    manifest_ids = {int(row["local_chunk_id"]) for row in manifest}
    unexpected_scores = set(scores) - manifest_ids
    unexpected_events = set(events) - manifest_ids
    if unexpected_scores:
        raise SystemExit(f"unexpected CNN result chunks: {sorted(unexpected_scores)}")
    if unexpected_events:
        raise SystemExit(f"unexpected event chunks: {sorted(unexpected_events)}")

    base_columns = [
        "source_chunk_id",
        "local_chunk_id",
        "label",
        "input_batch_index",
        "input_time_ns",
        "input_first_fire_time_ns",
        "input_last_fire_time_ns",
        "input_stream_complete",
        "input_valid",
        "sim_input_ready",
        "input_fire",
    ]
    cnn_columns = [
        "cnn_result_seen",
        "cnn_result_time_ns",
        "cnn_score_hex",
        "cnn_score_float",
        "cnn_threshold_raw",
        "cnn_threshold_float",
        "trigger_decision",
        "cnn_latency_cycles",
        "cnn_latency_ns",
    ]
    event_columns = [
        "event_present",
        "event_index",
        "event_output_time_ns",
        "event_valid",
        "event_ready",
        "event_fire",
        "event_chunk_id",
        "event_timestamp",
        "event_score_hex",
        "event_batch_index",
        "event_last",
    ]
    result_columns = [
        "waveform_match",
        "event_beat_count",
        "event_complete",
        "signal_readout_ok",
        "noise_ignored_ok",
        "continuous_readout_ok",
        *health,
    ]
    fieldnames = [
        *base_columns,
        *waveform_columns("input"),
        *cnn_columns,
        *event_columns,
        *waveform_columns("event"),
        *result_columns,
    ]

    report_rows: list[dict[str, object]] = []
    for manifest_row in manifest:
        local_chunk_id = int(manifest_row["local_chunk_id"])
        source_chunk_id = int(manifest_row["source_chunk_id"])
        label = int(manifest_row["label"])
        if local_chunk_id not in scores:
            raise SystemExit(f"missing CNN result for local chunk {local_chunk_id}")
        score = scores[local_chunk_id]
        if int(score["label"]) != label:
            raise SystemExit(
                f"label mismatch for local chunk {local_chunk_id}: "
                f"manifest={label}, score_csv={score['label']}"
            )
        input_batches = unpack_input_chunk(
            out_dir / "testhex_stream" / f"test_input_sample{local_chunk_id}.hex",
            mirror_raw_channels,
        )

        score_raw_container = int(score["hex_out"], 0)
        score_raw22 = signed_bits(score_raw_container & ((1 << 22) - 1), 22)
        trigger_decision = int(score_raw22 > cnn_thresh_raw)
        if int(score["prediction"]) != trigger_decision:
            raise SystemExit(
                f"threshold decision mismatch for local chunk {local_chunk_id}: "
                f"score_csv={score['prediction']}, recomputed={trigger_decision}"
            )
        chunk_events = events.get(local_chunk_id, {})
        event_present = bool(chunk_events)
        event_beat_count = sum(
            int(row.get("event_fire", "1")) for row in chunk_events.values()
        )
        event_indices = {
            int(row["event_index"]) for row in chunk_events.values()
        }
        event_scores = {
            int(row["event_score_hex"], 0) for row in chunk_events.values()
        }
        event_times = [
            int(chunk_events[index].get("event_output_time_ns", ""))
            for index in sorted(chunk_events)
            if chunk_events[index].get("event_output_time_ns", "") != ""
        ]
        event_complete = int(
            event_beat_count == BEATS_PER_CHUNK
            and set(chunk_events) == set(range(BEATS_PER_CHUNK))
            and len(event_indices) == 1
            and event_scores == {score_raw_container}
            and len(event_times) == BEATS_PER_CHUNK
            and all(left < right for left, right in zip(event_times, event_times[1:]))
            and all(
                int(row.get("event_valid", "1")) == 1
                and int(row.get("event_ready", "1")) == 1
                and int(row.get("event_fire", "1")) == 1
                for row in chunk_events.values()
            )
            and all(
                int(chunk_events[index]["event_last"]) == int(index == BEATS_PER_CHUNK - 1)
                for index in range(BEATS_PER_CHUNK)
            )
        )
        timestamps = {
            int(row["event_timestamp"]) for row in chunk_events.values()
        }
        timestamp_ok = (not event_present) or timestamps == {local_chunk_id}

        chunk_waveforms_match = True
        for batch_index, event_row in chunk_events.items():
            chunk_waveforms_match &= (
                unpack_event_batch(event_row["event_data_hex"])
                == input_batches[batch_index]
            )

        first_input_time = int(score.get("input_first_fire_time_ns", 0))
        last_input_time = int(score.get("input_last_fire_time_ns", 0))
        input_stream_complete = int(
            last_input_time - first_input_time == (BEATS_PER_CHUNK - 1) * 4
        )
        signal_readout_ok = int(
            label == 1
            and input_stream_complete == 1
            and trigger_decision == 1
            and event_present
            and event_complete == 1
            and timestamp_ok
            and chunk_waveforms_match
            and health_ok
        )
        noise_ignored_ok = int(
            label == 0
            and input_stream_complete == 1
            and trigger_decision == 0
            and not event_present
            and health_ok
        )

        for batch_index, input_batch in enumerate(input_batches):
            event = chunk_events.get(batch_index)
            event_batch = (
                unpack_event_batch(event["event_data_hex"]) if event is not None else None
            )
            row: dict[str, object] = {
                "source_chunk_id": source_chunk_id,
                "local_chunk_id": local_chunk_id,
                "label": label,
                "input_batch_index": batch_index,
                "input_time_ns": first_input_time + batch_index * 4,
                "input_first_fire_time_ns": first_input_time,
                "input_last_fire_time_ns": last_input_time,
                "input_stream_complete": input_stream_complete,
                "input_valid": 1,
                "sim_input_ready": 1,
                "input_fire": 1,
                "cnn_result_seen": 1,
                "cnn_result_time_ns": score.get("cnn_result_time_ns", ""),
                "cnn_score_hex": score["hex_out"],
                "cnn_score_float": score["float_out"],
                "cnn_threshold_raw": cnn_thresh_raw,
                "cnn_threshold_float": f"{cnn_thresh_raw / 2048.0:.6f}",
                "trigger_decision": trigger_decision,
                "cnn_latency_cycles": score["latency_cycles_cnn"],
                "cnn_latency_ns": f"{float(score['latency_us']) * 1000.0:.3f}",
                "event_present": int(event_present),
                "event_index": event["event_index"] if event is not None else "",
                "event_output_time_ns": (
                    event.get("event_output_time_ns", "") if event is not None else ""
                ),
                "event_valid": event.get("event_valid", "1") if event is not None else 0,
                "event_ready": event.get("event_ready", "1") if event is not None else 0,
                "event_fire": event.get("event_fire", "1") if event is not None else 0,
                "event_chunk_id": event["event_chunk_id"] if event is not None else "",
                "event_timestamp": event["event_timestamp"] if event is not None else "",
                "event_score_hex": event["event_score_hex"] if event is not None else "",
                "event_batch_index": (
                    event["event_batch_index"] if event is not None else ""
                ),
                "event_last": event["event_last"] if event is not None else 0,
                "waveform_match": (
                    int(event_batch == input_batch) if event_batch is not None else ""
                ),
                "event_beat_count": event_beat_count,
                "event_complete": event_complete,
                "signal_readout_ok": signal_readout_ok,
                "noise_ignored_ok": noise_ignored_ok,
                "continuous_readout_ok": "",
                **health,
            }
            add_waveform(row, "input", input_batch)
            if event_batch is not None:
                add_waveform(row, "event", event_batch)
            else:
                for column in waveform_columns("event"):
                    row[column] = ""
            report_rows.append(row)

    rows_by_chunk: dict[int, list[dict[str, object]]] = {}
    for row in report_rows:
        rows_by_chunk.setdefault(int(row["local_chunk_id"]), []).append(row)

    continuous_chunk_ids: set[int] = set()
    ordered_chunk_ids = sorted(rows_by_chunk)
    for left_id, right_id in zip(ordered_chunk_ids, ordered_chunk_ids[1:]):
        if right_id != left_id + 1:
            continue
        left_rows = rows_by_chunk[left_id]
        right_rows = rows_by_chunk[right_id]
        if not (
            int(left_rows[0]["signal_readout_ok"]) == 1
            and int(right_rows[0]["signal_readout_ok"]) == 1
        ):
            continue
        left_event_indices = {
            int(row["event_index"]) for row in left_rows if row["event_index"] != ""
        }
        right_event_indices = {
            int(row["event_index"]) for row in right_rows if row["event_index"] != ""
        }
        if (
            len(left_event_indices) != 1
            or len(right_event_indices) != 1
            or next(iter(right_event_indices)) != next(iter(left_event_indices)) + 1
        ):
            continue
        left_times = [
            int(row["event_output_time_ns"])
            for row in left_rows
            if row["event_output_time_ns"] != ""
        ]
        right_times = [
            int(row["event_output_time_ns"])
            for row in right_rows
            if row["event_output_time_ns"] != ""
        ]
        if left_times and right_times and max(left_times) < min(right_times):
            continuous_chunk_ids.update((left_id, right_id))

    for row in report_rows:
        row["continuous_readout_ok"] = int(
            int(row["local_chunk_id"]) in continuous_chunk_ids
        )

    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(report_rows)
    print(f"Wrote {len(report_rows)} beat rows to {report_path}")
    return report_path


def validate_report(path: Path) -> bool:
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    first_row_by_chunk = {
        int(row["local_chunk_id"]): row
        for row in rows
        if int(row["input_batch_index"]) == 0
    }
    failures: list[str] = []

    for chunk_id, row in sorted(first_row_by_chunk.items()):
        label = int(row["label"])
        if label == 1 and int(row["signal_readout_ok"]) != 1:
            failures.append(
                f"signal source_chunk_id={row['source_chunk_id']} was not read out completely"
            )
        if label == 0 and int(row["noise_ignored_ok"]) != 1:
            failures.append(
                f"noise source_chunk_id={row['source_chunk_id']} was not ignored"
            )

    ordered_ids = sorted(first_row_by_chunk)
    for left_id, right_id in zip(ordered_ids, ordered_ids[1:]):
        left = first_row_by_chunk[left_id]
        right = first_row_by_chunk[right_id]
        if (
            right_id == left_id + 1
            and int(left["label"]) == 1
            and int(right["label"]) == 1
            and (
                int(left["continuous_readout_ok"]) != 1
                or int(right["continuous_readout_ok"]) != 1
            )
        ):
            failures.append(
                "adjacent signals "
                f"source_chunk_id={left['source_chunk_id']},{right['source_chunk_id']} "
                "were not read out continuously"
            )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return False

    print(
        "PASS: complete signal readout, noise rejection, and all adjacent-signal "
        "continuous-readout requirements are satisfied."
    )
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--x-data",
        type=Path,
        default=Path("data/X_test_data_NSF_Jul_27.npy"),
    )
    parser.add_argument(
        "--labels",
        type=Path,
        default=Path("data/y_test_labels_NSF_Jul_27.npy"),
    )
    parser.add_argument("--source-chunk-base", type=int, default=490)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/nsf_jul_27_sim"),
    )
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="Generate testhex_stream and manifest.csv without launching Vivado.",
    )
    parser.add_argument(
        "--analyze-only",
        action="store_true",
        help="Build the final report CSV from existing XSim outputs.",
    )
    parser.add_argument("--scores-csv", type=Path)
    parser.add_argument("--events-csv", type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--report-csv", type=Path)
    parser.add_argument("--cnn-thresh-raw", type=int, default=0)
    parser.add_argument("--score-threshold", type=float, default=0.0)
    parser.add_argument("--mirror-raw-channels", type=int, choices=(0, 1), default=0)
    parser.add_argument(
        "--sim-runner",
        type=Path,
        default=Path("scripts/run_vivado_sim.py"),
        help="Vivado simulation launcher. Defaults to scripts/run_vivado_sim.py.",
    )
    parser.add_argument(
        "--xsim-log",
        type=Path,
        default=Path(
            "AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/simulate.log"
        ),
        help="simulate.log produced by XSim.",
    )
    parser.add_argument("--vivado", help="Optional Vivado executable passed to the launcher.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]

    def repo_path(path: Path) -> Path:
        return path if path.is_absolute() else repo_root / path

    out_dir = repo_path(args.out_dir).resolve()
    report_path = (
        repo_path(args.report_csv).resolve()
        if args.report_csv is not None
        else out_dir / "NSF_Jul_27_trigger_trace.csv"
    )

    if args.prepare_only and args.analyze_only:
        raise SystemExit("--prepare-only and --analyze-only are mutually exclusive")
    if args.analyze_only:
        report_path = build_report(
            out_dir,
            repo_path(args.scores_csv).resolve()
            if args.scores_csv is not None
            else out_dir / "scores.csv",
            repo_path(args.events_csv).resolve()
            if args.events_csv is not None
            else out_dir / "events.csv",
            repo_path(args.log).resolve()
            if args.log is not None
            else out_dir / "simulate.log",
            report_path,
            args.cnn_thresh_raw,
            args.mirror_raw_channels,
        )
        if not validate_report(report_path):
            raise SystemExit(1)
        return

    testhex_dir = prepare_stimulus(
        repo_path(args.x_data).resolve(),
        repo_path(args.labels).resolve(),
        out_dir,
        args.source_chunk_base,
    )
    if args.prepare_only:
        return

    expected_threshold_raw = round(args.score_threshold * 2048.0)
    if expected_threshold_raw != args.cnn_thresh_raw:
        raise SystemExit(
            "--score-threshold and --cnn-thresh-raw disagree: "
            f"{args.score_threshold} maps to raw {expected_threshold_raw}, "
            f"not {args.cnn_thresh_raw}"
        )

    num_samples = len(read_manifest(out_dir / "manifest.csv"))
    scores_path = out_dir / "scores.csv"
    events_path = out_dir / "events.csv"
    sim_runner = repo_path(args.sim_runner).resolve()
    command = [
        sys.executable,
        str(sim_runner),
        "--num-samples",
        str(num_samples),
        "--testhex-dir",
        str(testhex_dir.resolve()),
        "--out-csv",
        str(scores_path),
        "--event-csv",
        str(events_path),
        "--score-threshold",
        str(args.score_threshold),
        "--cnn-thresh-raw",
        str(args.cnn_thresh_raw),
        "--mirror-raw-channels",
        str(args.mirror_raw_channels),
    ]
    if args.vivado:
        command.extend(["--vivado", args.vivado])

    print("Running Vivado/XSim:", " ".join(command))
    subprocess.run(command, cwd=repo_root, check=True)

    xsim_log = repo_path(args.xsim_log).resolve()
    if not xsim_log.exists():
        raise SystemExit(f"XSim log not found after simulation: {xsim_log}")
    saved_log = out_dir / "simulate.log"
    if xsim_log != saved_log.resolve():
        shutil.copy2(xsim_log, saved_log)

    build_report(
        out_dir,
        scores_path,
        events_path,
        saved_log,
        report_path,
        args.cnn_thresh_raw,
        args.mirror_raw_channels,
    )
    if not validate_report(report_path):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
