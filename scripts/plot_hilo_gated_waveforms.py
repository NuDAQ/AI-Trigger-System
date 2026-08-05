#!/usr/bin/env python3
"""Plot the exact Hi-Lo-centered windows presented to the gated CNN.

The event CSV records the Hi-Lo anchor timestamp and beat offset.  The gated
reader starts 31 ADC beats before that anchor and streams 64 beats (256
samples) to the CNN.  This script reconstructs those windows from X_test,
applies the same input conversion as AI_TRIGGER_PKG.adc_to_axis16, and plots
amplitude in units of the background RMS measured from label-0 waveforms.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any, Sequence

import numpy as np


BEATS_PER_CHUNK = 64
SAMPLES_PER_BEAT = 4
WINDOW_BEATS = 64
PRETRIGGER_BEATS = 31
HILO_BATCH_BEATS = 4


def quantize_cnn_input(samples: np.ndarray) -> np.ndarray:
    """Match testhex rounding plus AI_TRIGGER_PKG.adc_to_axis16.

    X_test is converted to signed ap_fixed<12,6> raw codes, then the RTL drops
    one fractional bit and saturates to the signed 9-bit CNN input range.
    The returned values are in the original physical amplitude unit.
    """

    raw_12b = np.rint(np.asarray(samples, dtype=float) * 64.0).astype(np.int64)
    raw_9b = np.right_shift(raw_12b, 1)
    raw_9b = np.clip(raw_9b, -256, 255)
    return raw_9b.astype(float) / 32.0


def normalize_stream(x_test: np.ndarray) -> np.ndarray:
    stream = np.asarray(x_test)
    if stream.ndim == 4 and stream.shape[-1] == 1:
        stream = stream[..., 0]
    if stream.ndim != 3 or stream.shape[1:] != (4, 256):
        raise ValueError(f"expected X_test shape (N, 4, 256[, 1]), got {stream.shape}")
    return stream


def reconstruct_centered_windows(
    stream: np.ndarray,
    metadata: Sequence[dict[str, Any]],
) -> tuple[np.ndarray, list[dict[str, int]]]:
    """Reconstruct the 31+33-beat gated windows from event metadata."""

    stream = normalize_stream(stream)
    continuous = np.transpose(stream, (1, 0, 2)).reshape(4, -1)
    window_samples = WINDOW_BEATS * SAMPLES_PER_BEAT
    windows: list[np.ndarray] = []
    addresses: list[dict[str, int]] = []

    for item in metadata:
        timestamp = int(item["timestamp"])
        trigger_offset = int(item["trigger_offset"])
        anchor_beat = timestamp * BEATS_PER_CHUNK + trigger_offset
        start_beat = anchor_beat - PRETRIGGER_BEATS
        start_sample = start_beat * SAMPLES_PER_BEAT
        stop_sample = start_sample + window_samples
        if start_sample < 0 or stop_sample > continuous.shape[1]:
            raise ValueError(
                f"centered window [{start_sample}, {stop_sample}) lies outside the dataset"
            )
        windows.append(continuous[:, start_sample:stop_sample])
        addresses.append(
            {
                "start_chunk": start_beat // BEATS_PER_CHUNK,
                "start_offset": start_beat % BEATS_PER_CHUNK,
                # The Hi-Lo result is for the four-beat block ending here.
                # The reference recentering convention marks its right edge.
                "trigger_sample": (PRETRIGGER_BEATS + 1) * SAMPLES_PER_BEAT,
            }
        )

    if not windows:
        return np.empty((0, 4, window_samples), dtype=float), addresses
    return np.stack(windows), addresses


def read_event_metadata(path: Path) -> list[dict[str, int]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return []
    required = {
        "event_index",
        "event_chunk_id",
        "event_timestamp",
        "event_trigger_offset",
        "event_batch_index",
        "event_last",
    }
    if not required.issubset(rows[0]):
        raise ValueError(f"event CSV lacks required columns: {path}")

    grouped: dict[int, list[dict[str, str]]] = {}
    for row in rows:
        grouped.setdefault(int(row["event_index"]), []).append(row)

    metadata: list[dict[str, int]] = []
    for event_index in sorted(grouped):
        event_rows = grouped[event_index]
        batches = [int(row["event_batch_index"]) for row in event_rows]
        if batches != list(range(WINDOW_BEATS)):
            raise ValueError(f"event {event_index} is not a complete 64-beat event")
        if [int(row["event_last"]) for row in event_rows] != [0] * 63 + [1]:
            raise ValueError(f"event {event_index} has invalid EVENT_LAST framing")
        stable_fields = {
            name: {int(row[name]) for row in event_rows}
            for name in ("event_chunk_id", "event_timestamp", "event_trigger_offset")
        }
        if any(len(values) != 1 for values in stable_fields.values()):
            raise ValueError(f"event {event_index} metadata changes within the event")
        metadata.append(
            {
                "event_index": event_index,
                "start_chunk": stable_fields["event_chunk_id"].pop(),
                "timestamp": stable_fields["event_timestamp"].pop(),
                "trigger_offset": stable_fields["event_trigger_offset"].pop(),
            }
        )
    return metadata


def read_scores(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if rows and not {"sample_id", "float_out", "prediction"}.issubset(rows[0]):
        raise ValueError(f"score CSV lacks required columns: {path}")
    return rows


def background_rms(x_test: np.ndarray, labels: np.ndarray) -> float:
    stream = normalize_stream(x_test)
    labels = np.asarray(labels).reshape(-1)
    if len(labels) != len(stream):
        raise ValueError("label count does not match X_test")
    noise = stream[labels == 0]
    if noise.size == 0:
        raise ValueError("no label-0 waveforms available for RMS normalization")
    return float(np.std(noise))


def write_metadata_csv(
    path: Path,
    metadata: Sequence[dict[str, int]],
    addresses: Sequence[dict[str, int]],
    scores: Sequence[dict[str, str]],
    labels: np.ndarray,
) -> None:
    fieldnames = [
        "event_index",
        "anchor_timestamp",
        "anchor_beat_offset",
        "window_start_chunk",
        "window_start_beat_offset",
        "cnn_sample_id",
        "label",
        "cnn_score",
        "cnn_prediction",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for event, address, score in zip(metadata, addresses, scores):
            sample_id = int(score["sample_id"])
            anchor_timestamp = event["timestamp"]
            writer.writerow(
                {
                    "event_index": event["event_index"],
                    "anchor_timestamp": anchor_timestamp,
                    "anchor_beat_offset": event["trigger_offset"],
                    "window_start_chunk": address["start_chunk"],
                    "window_start_beat_offset": address["start_offset"],
                    "cnn_sample_id": sample_id,
                    # The gated input is newly centered and no longer equals a
                    # fixed dataset chunk.  Classification follows the event
                    # anchor timestamp, not the ring-buffer start chunk.
                    "label": int(labels[anchor_timestamp]),
                    "cnn_score": score["float_out"],
                    "cnn_prediction": score["prediction"],
                }
            )


def plot_windows(
    path: Path,
    windows_rms: np.ndarray,
    metadata: Sequence[dict[str, int]],
    addresses: Sequence[dict[str, int]],
    scores: Sequence[dict[str, str]],
    labels: np.ndarray,
    threshold_rms: float,
) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    count = len(windows_rms)
    if count == 0:
        raise ValueError("no gated CNN windows to plot")
    columns = 4
    rows = math.ceil(count / columns)
    fig, axes = plt.subplots(rows, columns, figsize=(15, 2.55 * rows), sharex=True)
    axes_array = np.atleast_1d(axes).reshape(-1)
    colors = ("#1f77b4", "#ff7f0e", "#2ca02c", "#d62728")
    sample_axis = np.arange(windows_rms.shape[-1])

    for index, (axis, window, event, address, score) in enumerate(
        zip(axes_array, windows_rms, metadata, addresses, scores)
    ):
        sample_id = int(score["sample_id"])
        anchor_timestamp = event["timestamp"]
        for channel in range(4):
            axis.plot(
                sample_axis,
                window[channel],
                color=colors[channel],
                linewidth=0.65,
                alpha=0.88,
                label=f"Ch{channel}",
            )
        # PRE_TRIGGER consumes a four-beat (16-sample) group.  Its exact
        # crossing position is not exported, so show the complete decision bin.
        trigger_sample = address["trigger_sample"]
        axis.axvspan(
            trigger_sample - HILO_BATCH_BEATS * SAMPLES_PER_BEAT,
            trigger_sample,
            color="0.82",
            alpha=0.5,
        )
        axis.axvline(trigger_sample, color="black", linewidth=0.8, linestyle="--")
        axis.axhline(threshold_rms, color="0.35", linewidth=0.6, linestyle=":")
        axis.axhline(-threshold_rms, color="0.35", linewidth=0.6, linestyle=":")
        axis.set_title(
            f"#{index} anchor={anchor_timestamp} start={sample_id} "
            f"label={int(labels[anchor_timestamp])} "
            f"score={float(score['float_out']):.2f}",
            fontsize=8,
        )
        axis.grid(alpha=0.16, linewidth=0.4)

    for axis in axes_array[count:]:
        axis.set_visible(False)
    for axis in axes_array[-columns:]:
        if axis.get_visible():
            axis.set_xlabel("Recentered sample")
    for row_index in range(rows):
        axes_array[row_index * columns].set_ylabel("Amplitude / background RMS")
    handles, legend_labels = axes_array[0].get_legend_handles_labels()
    fig.legend(
        handles,
        legend_labels,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.978),
        ncol=4,
        frameon=False,
    )
    fig.suptitle(
        "Hi-Lo-gated CNN inputs (gray: 16-sample Hi-Lo decision bin; dashed: center)",
        y=0.998,
        fontsize=12,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.945))
    fig.savefig(path, dpi=180)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--x-npy", type=Path, required=True)
    parser.add_argument("--labels-npy", type=Path, required=True)
    parser.add_argument("--events-csv", type=Path, required=True)
    parser.add_argument("--scores-csv", type=Path, required=True)
    parser.add_argument("--hl-thresh-raw", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    x_test = np.load(args.x_npy)
    labels = np.load(args.labels_npy).reshape(-1).astype(int)
    rms = background_rms(x_test, labels)
    metadata = read_event_metadata(args.events_csv)
    scores = read_scores(args.scores_csv)
    if len(metadata) != len(scores):
        raise ValueError(
            f"event/score count mismatch: {len(metadata)} events, {len(scores)} scores"
        )

    quantized = quantize_cnn_input(normalize_stream(x_test))
    windows, addresses = reconstruct_centered_windows(quantized, metadata)
    for event, address, score in zip(metadata, addresses, scores):
        score_sample_id = int(score["sample_id"])
        if address["start_chunk"] != event["start_chunk"]:
            raise ValueError(
                f"event {event['event_index']} reconstructed start chunk "
                f"{address['start_chunk']} != EVENT_CHUNK_ID {event['start_chunk']}"
            )
        if score_sample_id != address["start_chunk"]:
            raise ValueError(
                f"event {event['event_index']} score sample_id {score_sample_id} != "
                f"reconstructed start chunk {address['start_chunk']}"
            )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    threshold_rms = args.hl_thresh_raw / (64.0 * rms)
    windows_rms = windows / rms
    plot_path = args.output_dir / "hilo_gated_centered_waveforms.png"
    metadata_path = args.output_dir / "hilo_gated_centered_metadata.csv"
    npz_path = args.output_dir / "hilo_gated_centered_waveforms.npz"
    summary_path = args.output_dir / "summary.json"
    plot_windows(
        plot_path,
        windows_rms,
        metadata,
        addresses,
        scores,
        labels,
        threshold_rms,
    )
    write_metadata_csv(metadata_path, metadata, addresses, scores, labels)
    np.savez_compressed(
        npz_path,
        waveforms_rms=windows_rms,
        background_rms=np.array(rms),
        threshold_rms=np.array(threshold_rms),
    )
    summary = {
        "windows": len(windows),
        "background_rms": rms,
        "raw_codes_per_rms": 64.0 * rms,
        "hl_threshold_raw": args.hl_thresh_raw,
        "hl_threshold_rms": threshold_rms,
        "plot": str(plot_path),
        "metadata_csv": str(metadata_path),
        "waveforms_npz": str(npz_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
