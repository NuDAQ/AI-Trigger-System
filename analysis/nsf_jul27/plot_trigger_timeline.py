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
EVENT_SAMPLE_PERIOD_NS = INPUT_SAMPLE_PERIOD_NS
EVENT_BEAT_PERIOD_NS = SAMPLES_PER_BEAT * EVENT_SAMPLE_PERIOD_NS
MODEL_INPUT_SCALE = 64.0
PAGE1_FIRST_CHUNK_CHANNEL = 1


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
    y_title_offset: float = 0.30,
) -> None:
    frame.SetTitle("")
    frame.GetYaxis().SetTitle(y_title)
    frame.GetYaxis().SetTitleSize(0.070)
    frame.GetYaxis().SetTitleOffset(y_title_offset)
    frame.GetYaxis().SetLabelSize(0.060)
    frame.GetYaxis().SetNdivisions(505)
    frame.GetXaxis().SetTitle("Time (ns)" if show_x_labels else "")
    frame.GetXaxis().SetTitleSize(0.075)
    frame.GetXaxis().SetTitleOffset(0.95)
    frame.GetXaxis().SetLabelSize(0.065 if show_x_labels else 0.0)
    frame.GetXaxis().SetNdivisions(510)


def make_pad(name: str, y_low: float, y_high: float, *, bottom_margin: float) -> ROOT.TPad:
    pad = ROOT.TPad(name, name, 0.035, y_low, 0.990, y_high)
    pad.SetLeftMargin(0.12)
    pad.SetRightMargin(0.015)
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
    *,
    show_labels: bool = True,
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

        if show_labels:
            text = f"{chunk + 1}  signal" if label else f"{chunk + 1}  noise"
            latex.DrawLatex((x_start + x_end) / 2.0, y_max * 0.83, text)

    boundary_tick_height = (y_max - y_min) * 0.08
    for chunk in range(1, 7):
        boundary_x = number(
            trace_by_chunk[chunk][0],
            "input_time_ns",
        )
        for tick_y_start, tick_y_end in (
            (y_min, y_min + boundary_tick_height),
            (y_max - boundary_tick_height, y_max),
        ):
            boundary_tick = ROOT.TLine(
                boundary_x,
                tick_y_start,
                boundary_x,
                tick_y_end,
            )
            boundary_tick.SetLineColor(colors["grid"])
            boundary_tick.SetLineWidth(2)
            boundary_tick.Draw("SAME")
            keepalive.append(boundary_tick)


def draw_report(
    trace_by_chunk: dict[int, list[dict[str, str]]],
    score_by_chunk: dict[int, dict[str, str]],
    event_by_chunk: dict[int, list[dict[str, str]]],
    noise_rms_model: float,
    output_dir: Path,
    basename: str,
) -> tuple[Path, Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    colors = configure_style()
    keepalive: list[object] = []

    input_x: list[float] = []
    input_raw_by_channel: dict[int, list[float]] = {
        channel: [] for channel in range(4)
    }
    for chunk in range(7):
        for row in trace_by_chunk[chunk]:
            beat_time = number(row, "input_time_ns")
            for sample in range(SAMPLES_PER_BEAT):
                input_x.append(beat_time + sample * INPUT_SAMPLE_PERIOD_NS)
                for channel in range(4):
                    input_raw_by_channel[channel].append(
                        float(integer(row, f"input_ch{channel}_s{sample}"))
                    )

    noise_rms_adc = noise_rms_model * MODEL_INPUT_SCALE
    input_y_by_channel = {
        channel: [
            value / noise_rms_adc
            for value in input_raw_by_channel[channel]
        ]
        for channel in range(4)
    }
    first_chunk_sample_count = BEATS_PER_CHUNK * SAMPLES_PER_BEAT
    page1_input_y = list(input_y_by_channel[0])
    page1_input_y[:first_chunk_sample_count] = input_y_by_channel[
        PAGE1_FIRST_CHUNK_CHANNEL
    ][:first_chunk_sample_count]

    output_graph_data: dict[int, tuple[list[float], list[float]]] = {}
    for chunk, event_rows in event_by_chunk.items():
        x_values: list[float] = []
        y_values: list[float] = []
        display_channel = (
            PAGE1_FIRST_CHUNK_CHANNEL
            if chunk == 0
            else 0
        )
        trace_rows = trace_by_chunk[chunk]
        for trace_row, event_row in zip(trace_rows, event_rows):
            beat_time = number(event_row, "event_output_time_ns")
            for sample in range(SAMPLES_PER_BEAT):
                x_values.append(
                    beat_time + sample * EVENT_SAMPLE_PERIOD_NS
                )
                y_values.append(
                    float(
                        integer(
                            trace_row,
                            f"event_ch{display_channel}_s{sample}",
                        )
                    )
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

    input_x_min = input_x[0]
    input_x_max = input_x[-1] + INPUT_SAMPLE_PERIOD_NS
    output_x_min = min(
        number(rows[0], "event_output_time_ns")
        for rows in event_by_chunk.values()
    )
    output_x_max = max(
        number(rows[-1], "event_output_time_ns") + EVENT_BEAT_PERIOD_NS
        for rows in event_by_chunk.values()
    )
    output_time_span = output_x_max - output_x_min
    first_event_rows = event_by_chunk[sorted(event_by_chunk)[0]]
    first_event_duration = (
        number(first_event_rows[-1], "event_output_time_ns")
        + EVENT_BEAT_PERIOD_NS
        - number(first_event_rows[0], "event_output_time_ns")
    )
    score_x_min = score_x[0] - first_event_duration / 2.0
    score_x_max = score_x_min + output_time_span

    amplitude_limit = max(
        5.0,
        max(abs(value) for value in page1_input_y) * 1.15,
    )
    four_channel_amplitude_limit = max(
        5.0,
        max(
            abs(value)
            for channel_values in input_y_by_channel.values()
            for value in channel_values
        )
        * 1.15,
    )

    canvas = ROOT.TCanvas(
        "c_nsf_jul27_trigger_timeline",
        "NSF Jul 27 AI trigger timeline",
        3600,
        2500,
    )
    canvas.SetFillColor(ROOT.kWhite)
    keepalive.append(canvas)

    input_pad = make_pad("input_pad", 0.685, 0.950, bottom_margin=0.18)
    score_pad = make_pad("score_pad", 0.365, 0.630, bottom_margin=0.18)
    output_pad = make_pad("output_pad", 0.045, 0.310, bottom_margin=0.18)
    keepalive.extend([input_pad, score_pad, output_pad])

    # input waveform.
    input_pad.cd()
    input_frame = input_pad.DrawFrame(
        input_x_min,
        -amplitude_limit,
        input_x_max,
        amplitude_limit,
    )
    style_frame(
        input_frame,
        y_title="Input / noise RMS",
        show_x_labels=True,
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
        page1_input_y,
        colors["input"],
        line_width=1,
    )
    input_graph.Draw("L SAME")
    input_frame.Draw("AXIS SAME")
    keepalive.extend([input_frame, input_graph])

    # CNN score and decision.
    score_pad.cd()
    score_min = -0.08
    score_max = 1.08
    score_frame = score_pad.DrawFrame(
        score_x_min,
        score_min,
        score_x_max,
        score_max,
    )
    style_frame(score_frame, y_title="Sigmoid score", show_x_labels=True)
    score_frame.GetYaxis().CenterTitle()
    threshold = ROOT.TLine(score_x_min, 0.5, score_x_max, 0.5)
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
            f"{score_y[chunk]:.3f}",
        )

    score_legend = ROOT.TLegend(0.80, 0.20, 0.98, 0.49)
    score_legend.SetBorderSize(1)
    score_legend.SetLineColor(ROOT.kBlack)
    score_legend.SetLineWidth(1)
    score_legend.SetFillStyle(1001)
    score_legend.SetFillColor(ROOT.kWhite)
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
        output_x_min,
        -amplitude_limit,
        output_x_max,
        amplitude_limit,
    )
    style_frame(
        output_frame,
        y_title="Output / noise RMS",
        show_x_labels=True,
    )
    output_frame.GetYaxis().CenterTitle()

    output_boxes: list[ROOT.TBox] = []
    output_graphs: list[ROOT.TGraph] = []
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
            line_width=1,
        )
        graph.Draw("L SAME")
        output_graphs.append(graph)

    output_frame.Draw("AXIS SAME")
    output_note = ROOT.TPaveText(0.31, 0.23, 0.60, 0.34, "NDC")
    output_note.SetBorderSize(0)
    output_note.SetFillColorAlpha(ROOT.kWhite, 0.82)
    output_note.SetTextFont(42)
    output_note.SetTextAlign(22)
    output_note.SetTextSize(0.043)
    output_note.SetTextColor(colors["output"])
    output_note.Draw()
    keepalive.extend(
        [output_frame, output_note, *output_boxes, *output_graphs]
    )

    canvas.cd()
    canvas.Update()

    # Page 2: original four-channel input waveforms only.
    channels_canvas = ROOT.TCanvas(
        "c_nsf_jul27_four_channel_input",
        "NSF Jul 27 four-channel input waveforms",
        3600,
        2500,
    )
    channels_canvas.SetFillColor(ROOT.kWhite)
    keepalive.append(channels_canvas)

    channel_pad_ranges = [
        (0.745, 0.955),
        (0.515, 0.725),
        (0.285, 0.495),
        (0.045, 0.265),
    ]
    channel_graphs: list[ROOT.TGraph] = []
    channel_frames: list[ROOT.TH1] = []
    channel_pads: list[ROOT.TPad] = []
    for channel, (y_low, y_high) in enumerate(channel_pad_ranges):
        channels_canvas.cd()
        show_x_labels = channel == 3
        pad = make_pad(
            f"input_ch{channel}_pad",
            y_low,
            y_high,
            bottom_margin=0.18 if show_x_labels else 0.02,
        )
        channel_pads.append(pad)
        pad.cd()
        frame = pad.DrawFrame(
            input_x_min,
            -four_channel_amplitude_limit,
            input_x_max,
            four_channel_amplitude_limit,
        )
        style_frame(
            frame,
            y_title=f"Ch{channel} input / noise RMS",
            show_x_labels=show_x_labels,
        )
        frame.GetYaxis().CenterTitle()
        add_chunk_backgrounds(
            keepalive,
            trace_by_chunk,
            -four_channel_amplitude_limit,
            four_channel_amplitude_limit,
            colors,
            show_labels=channel == 0,
        )
        graph = make_graph(
            f"g_ch{channel}_input_page2",
            input_x,
            input_y_by_channel[channel],
            colors["input"],
            line_width=1,
        )
        graph.Draw("L SAME")
        frame.Draw("AXIS SAME")
        channel_frames.append(frame)
        channel_graphs.append(graph)

    keepalive.extend(
        [
            *channel_pads,
            *channel_frames,
            *channel_graphs,
        ]
    )
    channels_canvas.cd()
    channels_canvas.Update()

    png_path = output_dir / f"{basename}.png"
    channels_png_path = output_dir / f"{basename}_4channel.png"
    pdf_path = output_dir / f"{basename}.pdf"
    root_path = output_dir / f"{basename}.root"
    canvas.SaveAs(str(png_path))
    channels_canvas.SaveAs(str(channels_png_path))
    canvas.Print(f"{pdf_path}[")
    canvas.Print(str(pdf_path))
    channels_canvas.Print(str(pdf_path))
    channels_canvas.Print(f"{pdf_path}]")

    root_file = ROOT.TFile(str(root_path), "RECREATE")
    canvas.Write()
    channels_canvas.Write()
    root_file.Close()

    return png_path, channels_png_path, pdf_path, root_path


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

    png_path, channels_png_path, pdf_path, root_path = draw_report(
        trace_by_chunk,
        score_by_chunk,
        event_by_chunk,
        noise_rms_model,
        args.output_dir.resolve(),
        args.basename,
    )
    print(f"Wrote {png_path}")
    print(f"Wrote {channels_png_path}")
    print(f"Wrote {pdf_path}")
    print(f"Wrote {root_path}")


if __name__ == "__main__":
    main()
