#!/usr/bin/env python3
"""Check AI_TRIGGER_TOP behavioral simulation results."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path


EVENT_BATCHES_PER_CAPTURE = 16


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
    parser.add_argument(
        "--event-csv",
        default=(
            "AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/"
            "ai_trigger_events.csv"
        ),
        help="Optional event waveform CSV path.",
    )
    parser.add_argument("--expected-samples", type=int, default=1000)
    parser.add_argument("--expected-cores", type=int, default=5)
    parser.add_argument("--expected-cnn-mhz", type=float, default=200.0)
    parser.add_argument("--expected-thresh-raw", type=int, default=0)
    parser.add_argument("--min-accuracy", type=float, default=0.90)
    parser.add_argument("--max-overflows", type=int, default=0)
    parser.add_argument(
        "--keras-model",
        type=Path,
        default=Path("/home/work1/Works/CNN-Core-Generator/cnn_core_project/keras_model.keras"),
        help="Optional Keras model for RTL-vs-model comparison.",
    )
    parser.add_argument(
        "--x-test",
        type=Path,
        default=Path("/home/work1/Works/CNN-Core-Generator/data/X_test_data.npy"),
        help="X_test .npy used for Keras comparison.",
    )
    parser.add_argument(
        "--y-test",
        type=Path,
        default=Path("/home/work1/Works/CNN-Core-Generator/data/y_test_labels.npy"),
        help="y_test .npy used for Keras comparison.",
    )
    parser.add_argument(
        "--keras-threshold",
        type=float,
        default=0.5,
        help="Keras score threshold for prediction agreement.",
    )
    parser.add_argument(
        "--min-prediction-agreement",
        type=float,
        default=0.85,
        help="Minimum RTL/Keras prediction agreement when Keras comparison is available.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/vivado_sim_analysis"),
        help="Directory for summary.json and keras_comparison.csv.",
    )
    return parser.parse_args()


def parse_summary_int(log_text: str, label: str) -> int | None:
    match = re.search(rf"^{re.escape(label)}:\s+(-?\d+)", log_text, re.MULTILINE)
    return int(match.group(1)) if match else None


def parse_summary_float(log_text: str, pattern: str) -> float | None:
    match = re.search(pattern, log_text, re.MULTILINE)
    return float(match.group(1)) if match else None


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def load_keras_model(path: Path):
    try:
        from tensorflow import keras
    except ImportError:
        try:
            import keras
        except ImportError as exc:
            raise SystemExit("TensorFlow/Keras is required for --keras-model comparison.") from exc

    custom_objects = {}
    try:
        from hgq.layers import QConv2D, QDense

        if not getattr(QConv2D, "_ai_trigger_ebops_compat", False):
            qconv2d_init = QConv2D.__init__

            def qconv2d_compat_init(self, *args, **kwargs):
                kwargs.pop("ebops_factor", None)
                qconv2d_init(self, *args, **kwargs)

            QConv2D.__init__ = qconv2d_compat_init
            QConv2D._ai_trigger_ebops_compat = True

        if not getattr(QDense, "_ai_trigger_ebops_compat", False):
            qdense_init = QDense.__init__

            def qdense_compat_init(self, *args, **kwargs):
                kwargs.pop("ebops_factor", None)
                qdense_init(self, *args, **kwargs)

            QDense.__init__ = qdense_compat_init
            QDense._ai_trigger_ebops_compat = True

        class CompatQConv2D(QConv2D):
            def __init__(self, *args, **kwargs):
                kwargs.pop("ebops_factor", None)
                super().__init__(*args, **kwargs)

            @classmethod
            def from_config(cls, config):
                config = dict(config)
                config.pop("ebops_factor", None)
                return super().from_config(config)

        class CompatQDense(QDense):
            def __init__(self, *args, **kwargs):
                kwargs.pop("ebops_factor", None)
                super().__init__(*args, **kwargs)

            @classmethod
            def from_config(cls, config):
                config = dict(config)
                config.pop("ebops_factor", None)
                return super().from_config(config)

        custom_objects.update({
            "QConv2D": CompatQConv2D,
            "QDense": CompatQDense,
            "hgq>QConv2D": CompatQConv2D,
            "hgq>QDense": CompatQDense,
        })
    except ImportError:
        pass

    for module_name, names in (
        ("hgq.constraints", ("MinMax",)),
        ("hgq.regularizers", ("MonoL1",)),
        ("hgq.quantizer.config", ("QuantizerConfig",)),
    ):
        try:
            module = __import__(module_name, fromlist=list(names))
        except ImportError:
            continue
        for name in names:
            value = getattr(module, name)
            custom_objects[name] = value
            custom_objects[f"hgq>{name}"] = value

    load_kwargs = {"custom_objects": custom_objects, "compile": False}
    try:
        return keras.models.load_model(path, safe_mode=False, **load_kwargs)
    except TypeError:
        return keras.models.load_model(path, **load_kwargs)


def flatten_binary_outputs(predictions) -> list[float]:
    import numpy as np

    values = np.asarray(predictions)
    if values.ndim == 1:
        return [float(value) for value in values]
    if values.ndim >= 2 and values.shape[-1] == 1:
        return [float(value) for value in values.reshape((values.shape[0], -1))[:, 0]]
    if values.ndim >= 2 and values.shape[-1] > 1:
        return [float(value) for value in values.reshape((values.shape[0], -1))[:, -1]]
    return [float(value) for value in values.reshape(-1)]


def flatten_labels(labels) -> list[int]:
    import numpy as np

    values = np.asarray(labels)
    if values.ndim == 1:
        return [int(round(float(value))) for value in values]
    if values.ndim >= 2 and values.shape[-1] == 1:
        return [int(round(float(value))) for value in values.reshape((values.shape[0], -1))[:, 0]]
    if values.ndim >= 2 and values.shape[-1] > 1:
        return [int(value) for value in np.argmax(values.reshape((values.shape[0], -1)), axis=1)]
    return [int(round(float(value))) for value in values.reshape(-1)]


def prepare_model_input(model, x_test):
    import numpy as np

    input_shape = model.input_shape[0] if isinstance(model.input_shape, list) else model.input_shape
    target_shape = tuple(dim for dim in input_shape[1:] if dim is not None)

    if tuple(x_test.shape[1:]) == target_shape:
        return x_test, "as_loaded"

    if len(target_shape) == 2 and x_test.ndim == 4 and x_test.shape[-1] == 1:
        squeezed = x_test[..., 0]
        if tuple(squeezed.shape[1:]) == target_shape:
            return squeezed, "squeeze_last_axis"
        transposed = np.transpose(squeezed, (0, 2, 1))
        if tuple(transposed.shape[1:]) == target_shape:
            return transposed, "transpose_from_channels_first_time_series"

    raise SystemExit(
        f"Could not reshape X_test from {tuple(x_test.shape)} to model input shape {input_shape}."
    )


def correlation(left: list[float], right: list[float]) -> float | None:
    if len(left) < 2 or len(left) != len(right):
        return None
    left_mean = sum(left) / len(left)
    right_mean = sum(right) / len(right)
    num = sum((a - left_mean) * (b - right_mean) for a, b in zip(left, right))
    den_left = math.sqrt(sum((a - left_mean) ** 2 for a in left))
    den_right = math.sqrt(sum((b - right_mean) ** 2 for b in right))
    if den_left == 0 or den_right == 0:
        return None
    return num / (den_left * den_right)


def compare_with_keras(args: argparse.Namespace, rows: list[dict[str, str]]) -> tuple[dict[str, object] | None, list[dict[str, object]]]:
    if not (args.keras_model.exists() and args.x_test.exists() and args.y_test.exists()):
        return None, []

    import numpy as np

    model = load_keras_model(args.keras_model)
    x_raw = np.load(args.x_test)
    y_test = flatten_labels(np.load(args.y_test))
    x_test, transform = prepare_model_input(model, x_raw)
    keras_scores = flatten_binary_outputs(model.predict(x_test, verbose=0))

    comparison_rows: list[dict[str, object]] = []
    rtl_scores: list[float] = []
    matched_keras_scores: list[float] = []
    agreements = 0
    label_mismatches = 0

    for row in rows:
        sample_id = int(row["sample_id"])
        if sample_id >= len(keras_scores) or sample_id >= len(y_test):
            continue
        rtl_score = float(row["float_out"])
        rtl_prediction = int(row["prediction"])
        rtl_label = int(row["label"])
        label = y_test[sample_id]
        keras_score = keras_scores[sample_id]
        keras_prediction = 1 if keras_score > args.keras_threshold else 0
        prediction_agree = 1 if rtl_prediction == keras_prediction else 0
        agreements += prediction_agree
        label_mismatches += 1 if rtl_label != label else 0

        rtl_scores.append(rtl_score)
        matched_keras_scores.append(keras_score)
        comparison_rows.append({
            "sample_id": sample_id,
            "label_csv": rtl_label,
            "label_npy": label,
            "rtl_score": rtl_score,
            "rtl_prediction": rtl_prediction,
            "keras_score": keras_score,
            "keras_prediction": keras_prediction,
            "prediction_agree": prediction_agree,
            "score_diff_rtl_minus_keras": rtl_score - keras_score,
            "abs_score_diff": abs(rtl_score - keras_score),
        })

    if not comparison_rows:
        return None, []

    abs_diffs = [float(row["abs_score_diff"]) for row in comparison_rows]
    summary = {
        "model_path": str(args.keras_model),
        "x_test_path": str(args.x_test),
        "y_test_path": str(args.y_test),
        "x_test_shape_raw": list(x_raw.shape),
        "x_test_shape_model": list(x_test.shape),
        "x_test_transform": transform,
        "num_compared": len(comparison_rows),
        "label_mismatches_between_csv_and_npy": label_mismatches,
        "keras_threshold": args.keras_threshold,
        "prediction_agreement": agreements / len(comparison_rows),
        "score_diff": {
            "mean_abs": sum(abs_diffs) / len(abs_diffs),
            "max_abs": max(abs_diffs),
            "correlation": correlation(rtl_scores, matched_keras_scores),
        },
    }
    return summary, comparison_rows


def analyze_event_csv(path: Path, errors: list[str]) -> dict[str, int | bool | str]:
    if not path.exists():
        return {"exists": False, "path": str(path), "rows": 0, "events": 0, "complete_events": 0}

    rows = list(csv.DictReader(path.open(newline="", encoding="utf-8")))
    required_cols = {
        "event_index",
        "event_chunk_id",
        "event_timestamp",
        "event_score_hex",
        "event_batch_index",
        "event_last",
        "event_data_hex",
    }
    if rows:
        missing = required_cols - set(rows[0])
        if missing:
            fail(errors, f"event CSV missing columns: {sorted(missing)}")

    batches_by_event: dict[int, int] = {}
    timestamp_by_event: dict[int, int] = {}
    complete_events = 0
    for i, row in enumerate(rows):
        try:
            event_index = int(row["event_index"])
            event_timestamp = int(row["event_timestamp"])
            batch_index = int(row["event_batch_index"])
            event_last = int(row["event_last"])
        except (KeyError, ValueError) as exc:
            fail(errors, f"event row {i} parse failed: {exc}")
            continue

        expected_batch = batches_by_event.get(event_index, 0)
        if batch_index != expected_batch:
            fail(errors, f"event {event_index} row {i} batch {batch_index}, expected {expected_batch}")
        batches_by_event[event_index] = expected_batch + 1

        expected_timestamp = timestamp_by_event.setdefault(event_index, event_timestamp)
        if event_timestamp != expected_timestamp:
            fail(
                errors,
                f"event {event_index} row {i} timestamp {event_timestamp}, "
                f"expected {expected_timestamp}",
            )

        if event_last:
            complete_events += 1
            if batches_by_event[event_index] != EVENT_BATCHES_PER_CAPTURE:
                fail(
                    errors,
                    f"event {event_index} has {batches_by_event[event_index]} batches, "
                    f"expected {EVENT_BATCHES_PER_CAPTURE}",
                )

        data_hex = row.get("event_data_hex", "")
        if data_hex and not re.fullmatch(r"0x[0-9a-fA-F]{384}", data_hex):
            fail(errors, f"event row {i} data is not 1536-bit hex")

    return {
        "exists": True,
        "path": str(path),
        "rows": len(rows),
        "events": len(batches_by_event),
        "complete_events": complete_events,
    }


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

    event_summary = analyze_event_csv(Path(args.event_csv), errors)
    if event_summary["exists"]:
        print(
            "  events:     "
            f"rows={event_summary['rows']} "
            f"events={event_summary['events']} "
            f"complete={event_summary['complete_events']}"
        )
    else:
        print(f"  events:     skipped (not found: {event_summary['path']})")

    keras_summary, comparison_rows = compare_with_keras(args, rows)
    if keras_summary is not None:
        agreement = float(keras_summary["prediction_agreement"])
        if agreement < args.min_prediction_agreement:
            fail(
                errors,
                f"RTL/Keras prediction agreement {agreement:.4f} < "
                f"minimum {args.min_prediction_agreement:.4f}",
            )

        args.out_dir.mkdir(parents=True, exist_ok=True)
        summary_path = args.out_dir / "summary.json"
        comparison_path = args.out_dir / "keras_comparison.csv"
        summary_path.write_text(json.dumps({
            "event_capture": event_summary,
            "keras_comparison": keras_summary,
        }, indent=2) + "\n")
        with comparison_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(comparison_rows[0]))
            writer.writeheader()
            writer.writerows(comparison_rows)

        print("  keras:     compared="
              f"{keras_summary['num_compared']} "
              f"agreement={agreement:.2%} "
              f"corr={keras_summary['score_diff']['correlation']}")
        print(f"  wrote:      {summary_path}")
        print(f"  wrote:      {comparison_path}")
    else:
        print("  keras:     skipped (model/X/Y files not found)")
        args.out_dir.mkdir(parents=True, exist_ok=True)
        summary_path = args.out_dir / "summary.json"
        summary_path.write_text(json.dumps({"event_capture": event_summary}, indent=2) + "\n")
        print(f"  wrote:      {summary_path}")

    if errors:
        print("\nFAIL:")
        for error in errors:
            print(f"  - {error}")
        return 1

    print("\nPASS: simulation output matches expected 5-lane wrapper-4 configuration.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
