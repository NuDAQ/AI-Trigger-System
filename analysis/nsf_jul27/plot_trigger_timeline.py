#!/usr/bin/env python3
"""Draw the NSF Jul 27 trigger/readout timeline with CERN PyROOT."""

from __future__ import annotations

import argparse
import csv
import math
import os
import sys
from array import array
from collections import defaultdict
from pathlib import Path

import numpy as np


if sys.platform == "darwin" and "EXTRA_CLING_ARGS" not in os.environ:
    xcode_libcxx = Path(
        "/Applications/Xcode.app/Contents/Developer/Platforms/"
        "MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/c++/v1"
    )
    if xcode_libcxx.is_dir():
        os.environ["EXTRA_CLING_ARGS"] = f"-I{xcode_libcxx}"

import ROOT


EXPECTED_SOURCE_CHUNKS = list(range(490, 497))
EXPECTED_LABELS = [1, 0, 0, 0, 0, 1, 1]
BEATS_PER_CHUNK = 64
SAMPLES_PER_BEAT = 4
INPUT_SAMPLE_PERIOD_NS = 1.0
EVENT_SAMPLE_DISPLAY_PERIOD_NS = 4.0
EVENT_BEAT_PERIOD_NS = 16.0
MODEL_INPUT_SCALE = 64.0


def load_background_noise_rms(
    data_path: Path,
    labels_path: Path,
) -> tuple[float, int]:
    waveforms = np.asarray(np.load(data_path))
    labels = np.asarray(np.load(labels_path)).reshape(-1)
    if waveforms.ndim == 4 and waveforms.shape[-1] == 1:
        waveforms = waveforms[..., 0]
    if waveforms.ndim != 3 or tuple(waveforms.shape[1:]) != (4, 256):
        raise SystemExit(
            "RMS reference data must have shape (N, 4, 256) or "
            f"(N, 4, 256, 1), got {waveforms.shape}"
        )
    if len(labels) != len(waveforms):
        raise SystemExit(
            "RMS reference waveform/label count mismatch: "
            f"{len(waveforms)} waveforms versus {len(labels)} labels"
        )

    rounded_labels = np.rint(labels).astype(np.int64)
    if not np.all((rounded_labels == 0) | (rounded_labels == 1)):
        raise SystemExit("RMS reference labels must contain only 0 or 1")
    pure_noise = waveforms[rounded_labels == 0]
    if len(pure_noise) == 0:
        raise SystemExit("RMS reference dataset contains no noise waveforms")

    noise_rms = float(np.std(pure_noise))
    if not math.isfinite(noise_rms) or noise_rms <= 0.0:
        raise SystemExit(f"invalid background noise RMS: {noise_rms}")
    return noise_rms, len(pure_noise)


def sigmoid(value: float) -> float:
    if value >= 0.0:
        exp_neg = math.exp(-value)
        return 1.0 / (1.0 + exp_neg)
    exp_pos = math.exp(value)
    return exp_pos / (1.0 + exp_pos)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if not rows:
        raise SystemExit(f"CSV has no data rows: {path}")
    return rows


def integer(row: dict[str, str], key: str) -> int:
    value = row.get(key, "")
    if value == "":
        raise SystemExit(f"missing integer field '{key}'")
    return int(value)


def number(row: dict[str, str], key: str) -> float:
    value = row.get(key, "")
    if value == "":
        raise SystemExit(f"missing numeric field '{key}'")
    return float(value)


def group_rows(
    rows: list[dict[str, str]], key: str
) -> dict[int, list[dict[str, str]]]:
    grouped: dict[int, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[integer(row, key)].append(row)
    return dict(grouped)


def validate_inputs(
    trace_rows: list[dict[str, str]],
    score_rows: list[dict[str, str]],
    event_rows: list[dict[str, str]],
) -> tuple[
    dict[int, list[dict[str, str]]],
    dict[int, dict[str, str]],
    dict[int, list[dict[str, str]]],
]:
    trace_by_chunk = group_rows(trace_rows, "local_chunk_id")
    score_by_chunk = {
        integer(row, "sample_id"): row
        for row in score_rows
    }
    event_by_chunk = group_rows(event_rows, "event_chunk_id")

    if sorted(trace_by_chunk) != list(range(7)):
        raise SystemExit(f"expected local chunks 0..6, got {sorted(trace_by_chunk)}")
    if sorted(score_by_chunk) != list(range(7)):
        raise SystemExit(f"expected seven score rows, got {sorted(score_by_chunk)}")

    source_chunks = [
        integer(trace_by_chunk[chunk][0], "source_chunk_id")
        for chunk in range(7)
    ]
    labels = [
        integer(trace_by_chunk[chunk][0], "label")
        for chunk in range(7)
    ]
    if source_chunks != EXPECTED_SOURCE_CHUNKS:
        raise SystemExit(
            f"expected source chunks {EXPECTED_SOURCE_CHUNKS}, got {source_chunks}"
        )
    if labels != EXPECTED_LABELS:
        raise SystemExit(f"expected labels {EXPECTED_LABELS}, got {labels}")

    expected_event_chunks = [
        chunk for chunk, label in enumerate(labels) if label == 1
    ]
    if sorted(event_by_chunk) != expected_event_chunks:
        raise SystemExit(
            f"expected event chunks {expected_event_chunks}, got {sorted(event_by_chunk)}"
        )

    previous_input_time: float | None = None
    for chunk in range(7):
        chunk_rows = sorted(
            trace_by_chunk[chunk],
            key=lambda row: integer(row, "input_batch_index"),
        )
        trace_by_chunk[chunk] = chunk_rows
        if len(chunk_rows) != BEATS_PER_CHUNK:
            raise SystemExit(
                f"chunk {chunk}: expected {BEATS_PER_CHUNK} input beats, "
                f"got {len(chunk_rows)}"
            )
        if [integer(row, "input_batch_index") for row in chunk_rows] != list(
            range(BEATS_PER_CHUNK)
        ):
            raise SystemExit(f"chunk {chunk}: input batch indexes are incomplete")
        if any(integer(row, "input_fire") != 1 for row in chunk_rows):
            raise SystemExit(f"chunk {chunk}: an input beat was not accepted")
        if any(integer(row, "input_stream_complete") != 1 for row in chunk_rows):
            raise SystemExit(f"chunk {chunk}: input stream is incomplete")
        for row in chunk_rows:
            input_time = number(row, "input_time_ns")
            if previous_input_time is not None and input_time <= previous_input_time:
                raise SystemExit("input transaction times are not strictly increasing")
            previous_input_time = input_time
            for counter in (
                "chunk_overflow_count",
                "adc_input_overflow_count",
                "dropped_trigger_count",
                "ring_miss_count",
            ):
                if integer(row, counter) != 0:
                    raise SystemExit(f"non-zero health counter: {counter}")

        score = score_by_chunk[chunk]
        decision = integer(score, "prediction")
        expected_decision = labels[chunk]
        if decision != expected_decision:
            raise SystemExit(
                f"chunk {chunk}: prediction {decision} != label {expected_decision}"
            )
        if (number(score, "float_out") > 0.0) != bool(expected_decision):
            raise SystemExit(f"chunk {chunk}: score has the wrong threshold sign")
        if (sigmoid(number(score, "float_out")) > 0.5) != bool(
            expected_decision
        ):
            raise SystemExit(
                f"chunk {chunk}: sigmoid score has the wrong threshold side"
            )

        event_present = integer(chunk_rows[0], "event_present")
        if event_present != expected_decision:
            raise SystemExit(
                f"chunk {chunk}: event_present={event_present}, "
                f"expected {expected_decision}"
            )
        if expected_decision:
            if any(integer(row, "signal_readout_ok") != 1 for row in chunk_rows):
                raise SystemExit(f"chunk {chunk}: signal_readout_ok failed")
        else:
            if any(integer(row, "noise_ignored_ok") != 1 for row in chunk_rows):
                raise SystemExit(f"chunk {chunk}: noise_ignored_ok failed")

    previous_event_time: float | None = None
    for event_index, chunk in enumerate(expected_event_chunks):
        chunk_events = sorted(
            event_by_chunk[chunk],
            key=lambda row: integer(row, "event_batch_index"),
        )
        event_by_chunk[chunk] = chunk_events
        if len(chunk_events) != BEATS_PER_CHUNK:
            raise SystemExit(
                f"event chunk {chunk}: expected {BEATS_PER_CHUNK} beats, "
                f"got {len(chunk_events)}"
            )
        if [integer(row, "event_batch_index") for row in chunk_events] != list(
            range(BEATS_PER_CHUNK)
        ):
            raise SystemExit(f"event chunk {chunk}: batch indexes are incomplete")
        if any(
            integer(row, "event_index") != event_index
            or integer(row, "event_timestamp") != chunk
            for row in chunk_events
        ):
            raise SystemExit(f"event chunk {chunk}: metadata is inconsistent")
        if any(
            integer(row, "event_valid") != 1
            or integer(row, "event_ready") != 1
            or integer(row, "event_fire") != 1
            for row in chunk_events
        ):
            raise SystemExit(f"event chunk {chunk}: handshake failure")
        if [
            integer(row, "event_last")
            for row in chunk_events
        ] != [0] * (BEATS_PER_CHUNK - 1) + [1]:
            raise SystemExit(f"event chunk {chunk}: EVENT_LAST is incorrect")

        trace_chunk = trace_by_chunk[chunk]
        for trace_row, event_row in zip(trace_chunk, chunk_events):
            if integer(trace_row, "input_batch_index") != integer(
                event_row, "event_batch_index"
            ):
                raise SystemExit(f"event chunk {chunk}: batch alignment failed")
            for sample in range(SAMPLES_PER_BEAT):
                input_value = integer(trace_row, f"input_ch0_s{sample}")
                event_value = integer(trace_row, f"event_ch0_s{sample}")
                raw_event_value = (
                    int(event_row["event_data_hex"], 0) >> (sample * 12)
                ) & 0xFFF
                if raw_event_value & 0x800:
                    raw_event_value -= 0x1000
                if input_value != event_value or input_value != raw_event_value:
                    raise SystemExit(
                        f"event chunk {chunk}: ch0 mismatch at "
                        f"batch {trace_row['input_batch_index']} sample {sample}"
                    )

            event_time = number(event_row, "event_output_time_ns")
            if previous_event_time is not None and event_time <= previous_event_time:
                raise SystemExit("event output times are not strictly increasing")
            previous_event_time = event_time

    if any(
        integer(trace_by_chunk[chunk][0], "continuous_readout_ok") != 1
        for chunk in (5, 6)
    ):
        raise SystemExit(
            "continuous-readout proof failed for the final two inputs"
        )

    return trace_by_chunk, score_by_chunk, event_by_chunk


def doubles(values: list[float]) -> array:
    return array("d", values)


def make_graph(
    name: str,
    x_values: list[float],
    y_values: list[float],
    color: int,
    *,
    line_width: int = 2,
    marker_style: int = 0,
    marker_size: float = 0.0,
) -> ROOT.TGraph:
    graph = ROOT.TGraph(len(x_values), doubles(x_values), doubles(y_values))
    graph.SetName(name)
    graph.SetLineColor(color)
    graph.SetLineWidth(line_width)
    if marker_style:
        graph.SetMarkerStyle(marker_style)
        graph.SetMarkerColor(color)
        graph.SetMarkerSize(marker_size)
    return graph


def configure_style() -> dict[str, int]:
    ROOT.gROOT.SetBatch(True)
    ROOT.gStyle.SetOptStat(0)
    ROOT.gStyle.SetTextFont(42)
    ROOT.gStyle.SetLabelFont(42, "XYZ")
    ROOT.gStyle.SetTitleFont(42, "XYZ")
    ROOT.gStyle.SetLegendFont(42)
    ROOT.gStyle.SetLineScalePS(1.0)
    ROOT.gStyle.SetEndErrorSize(0)

    return {
        "input": ROOT.TColor.GetColor("#355C7D"),
        "output": ROOT.TColor.GetColor("#D95F02"),
        "trigger": ROOT.TColor.GetColor("#198754"),
        "noise": ROOT.TColor.GetColor("#6C757D"),
        "threshold": ROOT.TColor.GetColor("#B02A37"),
        "grid": ROOT.TColor.GetColor("#D7DBDF"),
        "signal_fill": ROOT.TColor.GetColor("#DDF3E7"),
        "noise_fill": ROOT.TColor.GetColor("#EFF1F3"),
        "event_fill": ROOT.TColor.GetColor("#FCE7D8"),
        "text": ROOT.TColor.GetColor("#20252A"),
    }


def style_frame(
    frame: ROOT.TH1,
    *,
    y_title: str,
    show_x_labels: bool,
    y_title_offset: float = 0.72,
) -> None:
    frame.SetTitle("")
    frame.GetYaxis().SetTitle(y_title)
    frame.GetYaxis().SetTitleSize(0.070)
    frame.GetYaxis().SetTitleOffset(y_title_offset)
    frame.GetYaxis().SetLabelSize(0.060)
    frame.GetYaxis().SetNdivisions(505)
    frame.GetXaxis().SetTitle("Time (ns) (ns)" if show_x_labels else "")
    frame.GetXaxis().SetTitleSize(0.075)
    frame.GetXaxis().SetTitleOffset(0.95)
    frame.GetXaxis().SetLabelSize(0.065 if show_x_labels else 0.0)
    frame.GetXaxis().SetNdivisions(510)


def make_pad(name: str, y_low: float, y_high: float, *, bottom_margin: float) -> ROOT.TPad:
    pad = ROOT.TPad(name, name, 0.075, y_low, 0.985, y_high)
    pad.SetLeftMargin(0.15)
    pad.SetRightMargin(0.02)
    pad.SetTopMargin(0.055)
    pad.SetBottomMargin(bottom_margin)
    pad.SetTicks(1, 1)
    pad.Draw()
    return pad


def add_chunk_backgrounds(
    keepalive: list[object],
    trace_by_chunk: dict[int, list[dict[str, str]]],
    y_min: float,
    y_max: float,
    colors: dict[str, int],
) -> None:
    latex = ROOT.TLatex()
    latex.SetTextFont(42)
    latex.SetTextAlign(22)
    latex.SetTextSize(0.050)
    latex.SetTextColor(colors["text"])
    keepalive.append(latex)

    for chunk in range(7):
        rows = trace_by_chunk[chunk]
        x_start = number(rows[0], "input_time_ns")
        x_end = (
            number(rows[-1], "input_time_ns")
            + SAMPLES_PER_BEAT * INPUT_SAMPLE_PERIOD_NS
        )
        label = integer(rows[0], "label")
        box = ROOT.TBox(x_start, y_min, x_end, y_max)
        box.SetFillColorAlpha(
            colors["signal_fill"] if label else colors["noise_fill"],
            0.75,
        )
        box.SetLineColor(0)
        box.Draw("SAME")
        keepalive.append(box)

        text = f"{chunk + 1}  signal" if label else f"{chunk + 1}  noise"
        latex.DrawLatex((x_start + x_end) / 2.0, y_max * 0.83, text)


def draw_report(
    trace_by_chunk: dict[int, list[dict[str, str]]],
    score_by_chunk: dict[int, dict[str, str]],
    event_by_chunk: dict[int, list[dict[str, str]]],
    noise_rms_model: float,
    output_dir: Path,
    basename: str,
) -> tuple[Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    colors = configure_style()
    keepalive: list[object] = []

    input_x: list[float] = []
    input_raw_y: list[float] = []
    input_fire_x: list[float] = []
    for chunk in range(7):
        for row in trace_by_chunk[chunk]:
            beat_time = number(row, "input_time_ns")
            input_fire_x.append(beat_time)
            for sample in range(SAMPLES_PER_BEAT):
                input_x.append(beat_time + sample * INPUT_SAMPLE_PERIOD_NS)
                input_raw_y.append(
                    float(integer(row, f"input_ch0_s{sample}"))
                )

    noise_rms_adc = noise_rms_model * MODEL_INPUT_SCALE
    input_y = [value / noise_rms_adc for value in input_raw_y]

    output_graph_data: dict[int, tuple[list[float], list[float]]] = {}
    event_fire_x: list[float] = []
    for chunk, event_rows in event_by_chunk.items():
        x_values: list[float] = []
        y_values: list[float] = []
        trace_rows = trace_by_chunk[chunk]
        for trace_row, event_row in zip(trace_rows, event_rows):
            beat_time = number(event_row, "event_output_time_ns")
            event_fire_x.append(beat_time)
            for sample in range(SAMPLES_PER_BEAT):
                x_values.append(
                    beat_time + sample * EVENT_SAMPLE_DISPLAY_PERIOD_NS
                )
                y_values.append(
                    float(integer(trace_row, f"event_ch0_s{sample}"))
                    / noise_rms_adc
                )
        output_graph_data[chunk] = (x_values, y_values)

    score_x = [
        number(score_by_chunk[chunk], "cnn_result_time_ns")
        for chunk in range(7)
    ]
    raw_score_y = [
        number(score_by_chunk[chunk], "float_out")
        for chunk in range(7)
    ]
    score_y = [sigmoid(value) for value in raw_score_y]
    trigger_chunks = [chunk for chunk in range(7) if score_y[chunk] > 0.5]
    noise_chunks = [chunk for chunk in range(7) if score_y[chunk] <= 0.5]

    output_end = max(
        values[0][-1]
        for values in output_graph_data.values()
    )
    x_min = 180.0
    x_max = max(4700.0, output_end + 60.0)
    amplitude_limit = max(
        5.0,
        max(abs(value) for value in input_y) * 1.15,
    )

    canvas = ROOT.TCanvas(
        "c_nsf_jul27_trigger_timeline",
        "NSF Jul 27 AI trigger timeline",
        1800,
        1250,
    )
    canvas.SetFillColor(ROOT.kWhite)
    keepalive.append(canvas)

    input_pad = make_pad("input_pad", 0.705, 0.925, bottom_margin=0.02)
    score_pad = make_pad("score_pad", 0.495, 0.695, bottom_margin=0.02)
    output_pad = make_pad("output_pad", 0.265, 0.485, bottom_margin=0.02)
    lane_pad = make_pad("lane_pad", 0.065, 0.255, bottom_margin=0.25)
    keepalive.extend([input_pad, score_pad, output_pad, lane_pad])

    # Ch0 input waveform.
    input_pad.cd()
    input_frame = input_pad.DrawFrame(
        x_min,
        -amplitude_limit,
        x_max,
        amplitude_limit,
    )
    style_frame(
        input_frame,
        y_title="Ch0 input\n(amplitude / noise RMS)",
        show_x_labels=False,
    )
    input_frame.GetYaxis().CenterTitle()
    add_chunk_backgrounds(
        keepalive,
        trace_by_chunk,
        -amplitude_limit,
        amplitude_limit,
        colors,
    )
    input_graph = make_graph(
        "g_ch0_input",
        input_x,
        input_y,
        colors["input"],
        line_width=2,
    )
    input_graph.Draw("L SAME")
    input_frame.Draw("AXIS SAME")
    keepalive.extend([input_frame, input_graph])

    input_note = ROOT.TLatex()
    input_note.SetTextFont(42)
    input_note.SetTextSize(0.050)
    input_note.SetTextColor(colors["input"])
    input_note.DrawLatex(
        3150.0,
        amplitude_limit * 0.54,
        "All 448 input beats accepted",
    )
    input_note.DrawLatex(
        3150.0,
        amplitude_limit * 0.26,
        "Only Ch0 shown; noise RMS = "
        f"{noise_rms_model:.4f} ({noise_rms_adc:.2f} ADC codes)",
    )
    keepalive.append(input_note)

    # CNN score and decision.
    score_pad.cd()
    score_min = -0.08
    score_max = 1.08
    score_frame = score_pad.DrawFrame(x_min, score_min, x_max, score_max)
    style_frame(score_frame, y_title="Sigmoid score", show_x_labels=False)
    score_frame.GetYaxis().CenterTitle()
    threshold = ROOT.TLine(x_min, 0.5, x_max, 0.5)
    threshold.SetLineColor(colors["threshold"])
    threshold.SetLineStyle(2)
    threshold.SetLineWidth(2)
    threshold.Draw("SAME")

    trigger_graph = make_graph(
        "g_trigger_scores",
        [score_x[chunk] for chunk in trigger_chunks],
        [score_y[chunk] for chunk in trigger_chunks],
        colors["trigger"],
        marker_style=22,
        marker_size=1.7,
    )
    noise_graph = make_graph(
        "g_noise_scores",
        [score_x[chunk] for chunk in noise_chunks],
        [score_y[chunk] for chunk in noise_chunks],
        colors["noise"],
        marker_style=24,
        marker_size=1.4,
    )
    trigger_graph.Draw("P SAME")
    noise_graph.Draw("P SAME")

    score_text = ROOT.TLatex()
    score_text.SetTextFont(42)
    score_text.SetTextAlign(22)
    score_text.SetTextSize(0.052)
    for chunk in range(7):
        score_text.SetTextColor(
            colors["trigger"] if chunk in trigger_chunks else colors["noise"]
        )
        vertical_offset = 0.055
        score_text.DrawLatex(
            score_x[chunk],
            score_y[chunk] + vertical_offset,
            f"{chunk + 1}  {score_y[chunk]:.3f}",
        )

    score_legend = ROOT.TLegend(0.68, 0.19, 0.96, 0.85)
    score_legend.SetBorderSize(0)
    score_legend.SetFillStyle(0)
    score_legend.SetTextFont(42)
    score_legend.SetTextSize(0.055)
    score_legend.AddEntry(trigger_graph, "Valid trigger (score > 0.5)", "p")
    score_legend.AddEntry(noise_graph, "Noise ignored (score #leq 0.5)", "p")
    score_legend.AddEntry(threshold, "Decision threshold = 0.5", "l")
    score_legend.Draw()
    keepalive.extend(
        [
            score_frame,
            threshold,
            trigger_graph,
            noise_graph,
            score_text,
            score_legend,
        ]
    )

    # Ch0 event output waveform.
    output_pad.cd()
    output_frame = output_pad.DrawFrame(
        x_min,
        -amplitude_limit,
        x_max,
        amplitude_limit,
    )
    style_frame(
        output_frame,
        y_title="Ch0 output\n(amplitude / noise RMS)",
        show_x_labels=False,
    )
    output_frame.GetYaxis().CenterTitle()

    output_boxes: list[ROOT.TBox] = []
    output_graphs: list[ROOT.TGraph] = []
    output_text = ROOT.TLatex()
    output_text.SetTextFont(42)
    output_text.SetTextAlign(22)
    output_text.SetTextSize(0.050)
    output_text.SetTextColor(colors["text"])
    for chunk in sorted(event_by_chunk):
        event_rows = event_by_chunk[chunk]
        event_start = number(event_rows[0], "event_output_time_ns")
        event_end = number(event_rows[-1], "event_output_time_ns") + EVENT_BEAT_PERIOD_NS
        box = ROOT.TBox(event_start, -amplitude_limit, event_end, amplitude_limit)
        box.SetFillColorAlpha(colors["event_fill"], 0.70)
        box.SetLineColor(0)
        box.Draw("SAME")
        output_boxes.append(box)

        graph_x, graph_y = output_graph_data[chunk]
        graph = make_graph(
            f"g_ch0_output_chunk{chunk}",
            graph_x,
            graph_y,
            colors["output"],
            line_width=2,
        )
        graph.Draw("L SAME")
        output_graphs.append(graph)

        event_number = sorted(event_by_chunk).index(chunk) + 1
        timestamp = integer(event_rows[0], "event_timestamp")
        output_text.DrawLatex(
            (event_start + event_end) / 2.0,
            amplitude_limit * 0.83,
            f"Event {event_number}  |  timestamp {timestamp}  |  64/64 beats",
        )

    output_frame.Draw("AXIS SAME")
    output_note = ROOT.TLatex()
    output_note.SetTextFont(42)
    output_note.SetTextSize(0.047)
    output_note.SetTextColor(colors["output"])
    output_note.DrawLatex(
        340.0,
        -amplitude_limit * 0.78,
        "Ch0 integrity check: 0 mismatched samples",
    )
    keepalive.extend(
        [output_frame, output_text, output_note, *output_boxes, *output_graphs]
    )

    # Transaction timeline.
    lane_pad.cd()
    lane_frame = ROOT.TH2F(
        "h_transaction_lanes",
        "",
        10,
        x_min,
        x_max,
        3,
        0.0,
        3.0,
    )
    lane_frame.SetStats(0)
    lane_frame.GetYaxis().SetBinLabel(1, "Output accepted")
    lane_frame.GetYaxis().SetBinLabel(2, "CNN trigger")
    lane_frame.GetYaxis().SetBinLabel(3, "Input accepted")
    lane_frame.GetYaxis().SetLabelSize(0.095)
    lane_frame.GetYaxis().SetTickLength(0)
    lane_frame.GetXaxis().SetTitle("Time (ns)")
    lane_frame.GetXaxis().SetTitleSize(0.095)
    lane_frame.GetXaxis().SetTitleOffset(1.05)
    lane_frame.GetXaxis().SetLabelSize(0.080)
    lane_frame.GetXaxis().SetNdivisions(510)
    lane_frame.Draw()

    lane_boxes: list[ROOT.TBox] = []
    for chunk in sorted(event_by_chunk):
        event_rows = event_by_chunk[chunk]
        event_start = number(event_rows[0], "event_output_time_ns")
        event_end = number(event_rows[-1], "event_output_time_ns") + EVENT_BEAT_PERIOD_NS
        box = ROOT.TBox(event_start, 0.05, event_end, 0.95)
        box.SetFillColorAlpha(colors["event_fill"], 0.65)
        box.SetLineColor(0)
        box.Draw("SAME")
        lane_boxes.append(box)

    input_fire_graph = make_graph(
        "g_input_fire",
        input_fire_x,
        [2.5] * len(input_fire_x),
        colors["input"],
        marker_style=20,
        marker_size=0.35,
    )
    trigger_fire_graph = make_graph(
        "g_cnn_trigger",
        [score_x[chunk] for chunk in trigger_chunks],
        [1.5] * len(trigger_chunks),
        colors["trigger"],
        marker_style=22,
        marker_size=1.6,
    )
    event_fire_graph = make_graph(
        "g_event_fire",
        event_fire_x,
        [0.5] * len(event_fire_x),
        colors["output"],
        marker_style=20,
        marker_size=0.45,
    )
    input_fire_graph.Draw("P SAME")
    trigger_fire_graph.Draw("P SAME")
    event_fire_graph.Draw("P SAME")

    lane_text = ROOT.TLatex()
    lane_text.SetTextFont(42)
    lane_text.SetTextSize(0.071)
    lane_text.SetTextColor(colors["noise"])
    lane_text.DrawLatex(
        505.0,
        1.18,
        "Inputs 2-5 ignored: no trigger and no event output",
    )
    lane_text.SetTextColor(colors["trigger"])
    lane_text.DrawLatex(
        2870.0,
        1.18,
        "Inputs 6 and 7 trigger back-to-back",
    )
    lane_text.SetTextColor(colors["output"])
    lane_text.DrawLatex(
        3070.0,
        0.17,
        "Event 2 -> Event 3: continuous handover (20 ns), no missing beat",
    )
    keepalive.extend(
        [
            lane_frame,
            input_fire_graph,
            trigger_fire_graph,
            event_fire_graph,
            lane_text,
            *lane_boxes,
        ]
    )

    canvas.cd()
    canvas.Update()

    png_path = output_dir / f"{basename}.png"
    pdf_path = output_dir / f"{basename}.pdf"
    root_path = output_dir / f"{basename}.root"
    canvas.SaveAs(str(png_path))
    canvas.SaveAs(str(pdf_path))

    root_file = ROOT.TFile(str(root_path), "RECREATE")
    canvas.Write()
    root_file.Close()

    return png_path, pdf_path, root_path


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parents[1]
    default_data_dir = repo_root / "build" / "nsf_jul_27_sim"
    default_reference_dir = repo_root / "data"
    parser = argparse.ArgumentParser(
        description="Draw the NSF Jul 27 Ch0 trigger/readout timeline with PyROOT."
    )
    parser.add_argument(
        "--trace-csv",
        type=Path,
        default=default_data_dir / "NSF_Jul_27_trigger_trace.csv",
    )
    parser.add_argument(
        "--scores-csv",
        type=Path,
        default=default_data_dir / "scores.csv",
    )
    parser.add_argument(
        "--events-csv",
        type=Path,
        default=default_data_dir / "events.csv",
    )
    parser.add_argument(
        "--rms-data-npy",
        type=Path,
        default=default_reference_dir / "X_test_data.npy",
        help="full waveform dataset used to calculate the background-noise RMS",
    )
    parser.add_argument(
        "--rms-labels-npy",
        type=Path,
        default=default_reference_dir / "y_test_labels.npy",
        help="labels selecting noise entries in the RMS reference dataset",
    )
    parser.add_argument("--output-dir", type=Path, default=script_dir)
    parser.add_argument(
        "--basename",
        default="nsf_jul27_trigger_timeline",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate the CSV inputs without rendering the ROOT figure",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    trace_rows = read_csv(args.trace_csv.resolve())
    score_rows = read_csv(args.scores_csv.resolve())
    event_rows = read_csv(args.events_csv.resolve())
    trace_by_chunk, score_by_chunk, event_by_chunk = validate_inputs(
        trace_rows,
        score_rows,
        event_rows,
    )
    noise_rms_model, noise_waveform_count = load_background_noise_rms(
        args.rms_data_npy.resolve(),
        args.rms_labels_npy.resolve(),
    )
    noise_rms_adc = noise_rms_model * MODEL_INPUT_SCALE
    print(
        "PASS: 7 chunks, 3 complete events, 4 ignored noise chunks, "
        "and the final two inputs read out continuously."
    )
    print(
        "Background noise RMS from "
        f"{noise_waveform_count} full-dataset noise waveforms: "
        f"{noise_rms_model:.6f} model units = "
        f"{noise_rms_adc:.6f} ADC codes."
    )
    if args.validate_only:
        return

    png_path, pdf_path, root_path = draw_report(
        trace_by_chunk,
        score_by_chunk,
        event_by_chunk,
        noise_rms_model,
        args.output_dir.resolve(),
        args.basename,
    )
    print(f"Wrote {png_path}")
    print(f"Wrote {pdf_path}")
    print(f"Wrote {root_path}")


if __name__ == "__main__":
    main()
