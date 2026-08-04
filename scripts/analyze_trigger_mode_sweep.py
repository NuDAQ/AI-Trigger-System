#!/usr/bin/env python3
"""Compare all runtime trigger modes on one testhex dataset.

The final event stream is the decision seam. Capture-All and External modes
are housekeeping policies, so they are checked against their acquisition
contracts rather than reported as classifiers. AI, Hi-Lo, and Hi-Lo-Gated AI
are compared with the dataset labels using the event timestamp as the trigger
chunk identity.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any, Sequence


MODE_NAMES = {
    0: "capture_all",
    1: "external",
    2: "ai",
    3: "hilo",
    4: "hilo_ai",
}
EVENT_BEATS = 64


def read_labels(path: Path) -> list[int]:
    labels = [int(value, 16) for value in path.read_text(encoding="utf-8").split()]
    if not labels or any(label not in (0, 1) for label in labels):
        raise ValueError(f"labels must contain only binary values: {path}")
    return labels


def read_score_rows(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise FileNotFoundError(f"score CSV not found: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if rows and not {"sample_id", "prediction"}.issubset(rows[0]):
        raise ValueError(f"score CSV lacks sample_id/prediction: {path}")
    return rows


def read_complete_events(path: Path) -> list[int]:
    if not path.is_file():
        raise FileNotFoundError(f"event CSV not found: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return []
    required = {"event_index", "event_timestamp", "event_batch_index", "event_last"}
    if not required.issubset(rows[0]):
        raise ValueError(f"event CSV lacks required columns: {path}")

    by_event: dict[int, list[dict[str, str]]] = {}
    for row in rows:
        by_event.setdefault(int(row["event_index"]), []).append(row)

    sample_ids: list[int] = []
    for event_index in sorted(by_event):
        event_rows = by_event[event_index]
        batches = [int(row["event_batch_index"]) for row in event_rows]
        timestamps = {int(row["event_timestamp"]) for row in event_rows}
        lasts = [int(row["event_last"]) for row in event_rows]
        if batches != list(range(EVENT_BEATS)):
            raise ValueError(f"event {event_index} is not a complete {EVENT_BEATS}-beat event")
        if len(timestamps) != 1 or lasts != [0] * (EVENT_BEATS - 1) + [1]:
            raise ValueError(f"event {event_index} metadata is not stable/complete")
        sample_ids.append(timestamps.pop())
    return sample_ids


def classification_metrics(labels: Sequence[int], positives: set[int]) -> dict[str, int | float]:
    tp = tn = fp = fn = 0
    for sample_id, label in enumerate(labels):
        prediction = int(sample_id in positives)
        if label == 1 and prediction == 1:
            tp += 1
        elif label == 0 and prediction == 0:
            tn += 1
        elif label == 0 and prediction == 1:
            fp += 1
        else:
            fn += 1

    def ratio(numerator: int, denominator: int) -> float:
        return numerator / denominator if denominator else 0.0

    return {
        "tp": tp,
        "tn": tn,
        "fp": fp,
        "fn": fn,
        "accuracy": ratio(tp + tn, len(labels)),
        "recall": ratio(tp, tp + fn),
        "false_positive_rate": ratio(fp, fp + tn),
        "precision": ratio(tp, tp + fp),
    }


def analyze_mode(
    mode: int,
    labels: Sequence[int],
    score_csv: Path,
    event_csv: Path,
    *,
    force_trigger_interval: int,
) -> dict[str, Any]:
    if mode not in MODE_NAMES:
        raise ValueError(f"unsupported trigger mode: {mode}")
    if force_trigger_interval < 0:
        raise ValueError("force_trigger_interval must be non-negative")

    score_rows = read_score_rows(score_csv)
    event_sample_ids = read_complete_events(event_csv)
    out_of_range = sorted(
        sample_id for sample_id in set(event_sample_ids) if not 0 <= sample_id < len(labels)
    )
    if out_of_range:
        raise ValueError(f"event timestamps outside dataset range: {out_of_range[:8]}")

    event_positives = set(event_sample_ids)
    score_predictions = [int(row["prediction"]) for row in score_rows]
    if any(prediction not in (0, 1) for prediction in score_predictions):
        raise ValueError(f"score CSV has a non-binary prediction: {score_csv}")

    result: dict[str, Any] = {
        "mode": f"{mode:04b}",
        "name": MODE_NAMES[mode],
        "events": len(event_sample_ids),
        "unique_event_chunks": len(event_positives),
        "duplicate_event_chunks": len(event_sample_ids) - len(event_positives),
        "cnn_evaluated": len(score_rows),
        "cnn_accepted": sum(score_predictions),
        "classification": None,
        "contract": {},
    }

    if mode == 0:
        expected = set(range(len(labels)))
        result["contract"] = {
            "name": "capture_every_chunk",
            "expected_events": len(expected),
            "exact_match": event_positives == expected and len(event_sample_ids) == len(expected),
            "missing_chunks": sorted(expected - event_positives),
            "unexpected_chunks": sorted(event_positives - expected),
        }
    elif mode == 1:
        expected = (
            set(range(0, len(labels), force_trigger_interval))
            if force_trigger_interval > 0
            else set()
        )
        result["contract"] = {
            "name": "scheduled_force_trigger",
            "expected_events": len(expected),
            "exact_match": event_positives == expected and len(event_sample_ids) == len(expected),
            "missing_chunks": sorted(expected - event_positives),
            "unexpected_chunks": sorted(event_positives - expected),
        }
    else:
        result["classification"] = classification_metrics(labels, event_positives)
        if mode == 2:
            score_positives = {
                int(row["sample_id"])
                for row in score_rows
                if int(row["prediction"]) == 1
            }
            result["contract"] = {
                "name": "continuous_ai_final_events",
                "all_chunks_evaluated": len(score_rows) == len(labels),
                "score_event_exact_match": score_positives == event_positives,
                "positive_scores_without_event": sorted(score_positives - event_positives),
                "events_without_positive_score": sorted(event_positives - score_positives),
            }
        elif mode == 3:
            result["contract"] = {
                "name": "hilo_final_events",
                "cnn_unused": len(score_rows) == 0,
            }
        else:
            result["contract"] = {
                "name": "hilo_gated_ai_final_events",
                "accepted_score_count_matches_events": sum(score_predictions)
                == len(event_sample_ids),
            }
    return result


def parse_log_status(path: Path) -> dict[str, int]:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    fields = {
        "dropped_triggers": r"Dropped triggers:\s+(\d+)",
        "ring_misses": r"Ring misses:\s+(\d+)",
        "event_loss": r"Event loss:\s+(\d+)",
        "adc_input_overflows": r"ADC input overflows:\s+(\d+)",
    }
    status: dict[str, int] = {}
    for name, pattern in fields.items():
        match = re.search(pattern, text)
        if match:
            status[name] = int(match.group(1))
    return status


def hilo_reference(
    x_npy: Path,
    labels: Sequence[int],
    *,
    threshold: int,
    hilo_window: int,
    coinc_window: int,
    bin_thr: int,
) -> tuple[set[int], dict[str, int | float]]:
    import numpy as np

    x_test = np.load(x_npy)
    if x_test.ndim == 4 and x_test.shape[-1] == 1:
        x_test = x_test[..., 0]
    if x_test.shape != (len(labels), 4, 256):
        raise ValueError(f"unexpected X_test shape {x_test.shape}, expected ({len(labels)}, 4, 256)")

    # The wrapper testhex generator rounds to the nearest ap_fixed<12,6> code.
    x_int = np.rint(x_test * 64.0).astype(np.int32)
    crossed_hi = x_int > threshold
    crossed_lo = x_int < -threshold
    gates_hi = np.zeros_like(crossed_hi)
    gates_lo = np.zeros_like(crossed_lo)
    for shift in range(hilo_window):
        if shift == 0:
            gates_hi |= crossed_hi
            gates_lo |= crossed_lo
        else:
            gates_hi[:, :, shift:] |= crossed_hi[:, :, :-shift]
            gates_lo[:, :, shift:] |= crossed_lo[:, :, :-shift]
    bipolar = gates_hi & gates_lo
    coincidence = np.zeros_like(bipolar)
    for shift in range(coinc_window):
        if shift == 0:
            coincidence |= bipolar
        else:
            coincidence[:, :, shift:] |= bipolar[:, :, :-shift]
    triggered = np.any(np.sum(coincidence, axis=1) >= bin_thr, axis=1)
    positives = set(int(index) for index in np.flatnonzero(triggered))
    return positives, classification_metrics(labels, positives)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sweep-dir", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--force-trigger-interval", type=int, default=4)
    parser.add_argument("--x-npy", type=Path)
    parser.add_argument("--hl-thresh", type=int, default=192)
    parser.add_argument("--hilo-window", type=int, default=5)
    parser.add_argument("--coinc-window", type=int, default=32)
    parser.add_argument("--bin-thr", type=int, default=2)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    labels = read_labels(args.labels)
    modes: list[dict[str, Any]] = []
    for mode in MODE_NAMES:
        mode_dir = args.sweep_dir / f"mode_{mode:04b}"
        result = analyze_mode(
            mode,
            labels,
            mode_dir / "scores.csv",
            mode_dir / "events.csv",
            force_trigger_interval=args.force_trigger_interval,
        )
        result["status"] = parse_log_status(mode_dir / "simulate.log")
        modes.append(result)

    report: dict[str, Any] = {
        "dataset": {"labels": str(args.labels), "samples": len(labels), "positive_labels": sum(labels)},
        "configuration": {
            "force_trigger_interval": args.force_trigger_interval,
            "hl_thresh": args.hl_thresh,
            "hilo_window": args.hilo_window,
            "coinc_window": args.coinc_window,
            "bin_thr": args.bin_thr,
        },
        "modes": modes,
    }
    if args.x_npy:
        reference_positives, reference_metrics = hilo_reference(
            args.x_npy,
            labels,
            threshold=args.hl_thresh,
            hilo_window=args.hilo_window,
            coinc_window=args.coinc_window,
            bin_thr=args.bin_thr,
        )
        hilo_result = next(item for item in modes if item["mode"] == "0011")
        rtl_positives = set(read_complete_events(args.sweep_dir / "mode_0011" / "events.csv"))
        report["hilo_software_reference"] = {
            "scope": "independent fixed chunks; excludes integration busy/blanking",
            "positive_chunks": len(reference_positives),
            "classification": reference_metrics,
            "rtl_decision_agreement": 1.0
            - len(reference_positives ^ rtl_positives) / len(labels),
            "rtl_final_events": hilo_result["events"],
        }

    output = args.output or args.sweep_dir / "summary.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"INFO: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
