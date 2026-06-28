#!/usr/bin/env python3
"""Check AI_TRIGGER_TOP behavioral simulation results."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate tb_AI_TRIGGER_TOP CSV/log output from Vivado xsim."
    )
    parser.add_argument(
        "csv",
        nargs="?",
        default=(
            "AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/"
            "ai_trigger_results.csv"
        ),
        help="Simulation CSV path.",
    )
    parser.add_argument(
        "--log",
        default=(
            "AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/"
            "simulate.log"
        ),
        help="xsim simulate.log path.",
    )
    parser.add_argument("--expected-samples", type=int, default=1000)
    parser.add_argument("--expected-cores", type=int, default=5)
    parser.add_argument("--expected-cnn-mhz", type=float, default=200.0)
    parser.add_argument("--expected-thresh-raw", type=int, default=-12288)
    parser.add_argument("--min-accuracy", type=float, default=0.90)
    parser.add_argument("--max-overflows", type=int, default=0)
    return parser.parse_args()


def parse_summary_int(log_text: str, label: str) -> int | None:
    match = re.search(rf"^{re.escape(label)}:\s+(-?\d+)", log_text, re.MULTILINE)
    return int(match.group(1)) if match else None


def parse_summary_float(log_text: str, pattern: str) -> float | None:
    match = re.search(pattern, log_text, re.MULTILINE)
    return float(match.group(1)) if match else None


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def main() -> int:
    args = parse_args()
    csv_path = Path(args.csv)
    log_path = Path(args.log)
    errors: list[str] = []

    if not csv_path.exists():
        print(f"ERROR: CSV not found: {csv_path}", file=sys.stderr)
        return 2

    rows = list(csv.DictReader(csv_path.open(newline="", encoding="utf-8")))
    if len(rows) != args.expected_samples:
        fail(errors, f"row count {len(rows)} != expected {args.expected_samples}")

    required_cols = {
        "sample_id",
        "hex_out",
        "float_out",
        "label",
        "prediction",
        "correct",
        "latency_cycles_cnn",
        "latency_us",
    }
    if rows:
        missing = required_cols - set(rows[0])
        if missing:
            fail(errors, f"CSV missing columns: {sorted(missing)}")

    correct = 0
    latencies: list[int] = []
    labels = {0: 0, 1: 0}
    predictions = {0: 0, 1: 0}
    score_min = None
    score_max = None
    wide_hex_seen = False

    for i, row in enumerate(rows):
        try:
            sample_id = int(row["sample_id"])
            label = int(row["label"])
            prediction = int(row["prediction"])
            is_correct = int(row["correct"])
            latency = int(row["latency_cycles_cnn"])
            score = float(row["float_out"])
        except (KeyError, ValueError) as exc:
            fail(errors, f"row {i} parse failed: {exc}")
            continue

        if sample_id != i:
            fail(errors, f"row {i} has sample_id {sample_id}")
        if label not in labels:
            fail(errors, f"row {i} label {label} is not 0/1")
        else:
            labels[label] += 1
        if prediction not in predictions:
            fail(errors, f"row {i} prediction {prediction} is not 0/1")
        else:
            predictions[prediction] += 1
        if is_correct not in (0, 1):
            fail(errors, f"row {i} correct {is_correct} is not 0/1")
        correct += is_correct
        latencies.append(latency)
        score_min = score if score_min is None else min(score_min, score)
        score_max = score if score_max is None else max(score_max, score)

        hex_out = row.get("hex_out", "")
        if re.fullmatch(r"0x[0-9a-fA-F]{8}", hex_out):
            wide_hex_seen = True

    if rows and not wide_hex_seen:
        fail(errors, "hex_out does not look like 32-bit wrapper-4 output")

    accuracy = correct / len(rows) if rows else 0.0
    if accuracy < args.min_accuracy:
        fail(errors, f"accuracy {accuracy:.4f} < minimum {args.min_accuracy:.4f}")

    log_text = ""
    if log_path.exists():
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        cores = parse_summary_int(log_text, "CNN cores")
        sent = parse_summary_int(log_text, "Samples sent")
        received = parse_summary_int(log_text, "Results received")
        overflows = parse_summary_int(log_text, "Chunk overflows")
        thresh = parse_summary_int(log_text, "CNN_THRESH")
        cnn_mhz = parse_summary_float(log_text, r"^CLK_CNN:\s+([0-9.]+)\s+MHz")

        if cores is not None and cores != args.expected_cores:
            fail(errors, f"log reports {cores} CNN cores, expected {args.expected_cores}")
        if sent is not None and sent != args.expected_samples:
            fail(errors, f"log sent {sent}, expected {args.expected_samples}")
        if received is not None and received != len(rows):
            fail(errors, f"log received {received}, CSV rows {len(rows)}")
        if overflows is not None and overflows > args.max_overflows:
            fail(errors, f"log overflows {overflows} > max {args.max_overflows}")
        if thresh is not None and thresh != args.expected_thresh_raw:
            fail(errors, f"log threshold {thresh}, expected {args.expected_thresh_raw}")
        if cnn_mhz is not None and abs(cnn_mhz - args.expected_cnn_mhz) > 0.1:
            fail(errors, f"log CLK_CNN {cnn_mhz} MHz, expected {args.expected_cnn_mhz}")
        if "Simulation complete." not in log_text:
            fail(errors, "log does not contain 'Simulation complete.'")
    else:
        fail(errors, f"log not found: {log_path}")

    print("Simulation result summary")
    print(f"  CSV:        {csv_path}")
    print(f"  rows:       {len(rows)}")
    print(f"  accuracy:   {correct}/{len(rows)} = {accuracy:.2%}" if rows else "  accuracy:   n/a")
    print(f"  labels:     0={labels[0]} 1={labels[1]}")
    print(f"  predicts:   0={predictions[0]} 1={predictions[1]}")
    if latencies:
        print(
            "  latency:    "
            f"min={min(latencies)} avg={sum(latencies)/len(latencies):.1f} "
            f"max={max(latencies)} CLK_CNN cycles"
        )
    if score_min is not None and score_max is not None:
        print(f"  score:      min={score_min:.6f} max={score_max:.6f}")

    if errors:
        print("\nFAIL:")
        for error in errors:
            print(f"  - {error}")
        return 1

    print("\nPASS: simulation output matches expected 5-lane wrapper-4 configuration.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
