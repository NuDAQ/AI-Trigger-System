#!/usr/bin/env python3
"""Generate and run DAQ bring-up simulation stimuli.

The generated ``testhex_stream`` directories use the existing Vivado
testbench input format: one chunk/sample is 256 lines of 64-bit hex, with
channels 0..3 packed into the low 48 bits of each timestep word.
"""

from __future__ import annotations

import argparse
import csv
import math
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


N_CHUNK_WORDS = 256
DEFAULT_ADC_VFS_MV = 800.0
DEFAULT_PULSE_MV = 50.0
PULSE_SEGMENT_SAMPLES = 5
PULSE_TOTAL_SAMPLES = PULSE_SEGMENT_SAMPLES * 2
LONG_MONOPOLAR_PULSE_MV = 100.0
LONG_MONOPOLAR_PULSE_SAMPLES = 100
ERF_EDGE_RISE_FALL_SAMPLES = 100
ERF_EDGE_SIGMA_SAMPLES = ERF_EDGE_RISE_FALL_SAMPLES / 2.563


@dataclass(frozen=True)
class StimulusCase:
    name: str
    samples: list[list[int]]
    manifest_rows: list[dict[str, str]]


def voltage_to_adc_code(voltage_mv: float, adc_vfs_mv: float) -> int:
    raw = round(voltage_mv * 4096.0 / adc_vfs_mv)
    return max(-2048, min(2047, raw))


def twos_complement_12(value: int) -> int:
    if value < -2048 or value > 2047:
        raise ValueError(f"12-bit ADC code out of range: {value}")
    return value & 0xFFF


def pack_timestep(ch_codes: list[int]) -> str:
    if len(ch_codes) != 4:
        raise ValueError("testhex timestep requires exactly four trigger channels")
    word = 0
    for channel, code in enumerate(ch_codes):
        word |= twos_complement_12(code) << (channel * 12)
    return f"{word:016x}"


def zero_chunk() -> list[int]:
    return [0] * N_CHUNK_WORDS


def bipolar_chunk(offset: int, pos_code: int, neg_code: int) -> list[int]:
    if offset < 0 or offset + PULSE_TOTAL_SAMPLES > N_CHUNK_WORDS:
        raise ValueError(f"bipolar offset {offset} does not fit in one chunk")
    chunk = zero_chunk()
    for idx in range(offset, offset + PULSE_SEGMENT_SAMPLES):
        chunk[idx] = pos_code
    for idx in range(offset + PULSE_SEGMENT_SAMPLES, offset + PULSE_TOTAL_SAMPLES):
        chunk[idx] = neg_code
    return chunk


def polar_chunk(offset: int, pos_code: int) -> list[int]:
    if offset < 0 or offset + PULSE_SEGMENT_SAMPLES > N_CHUNK_WORDS:
        raise ValueError(f"polar offset {offset} does not fit in one chunk")
    chunk = zero_chunk()
    for idx in range(offset, offset + PULSE_SEGMENT_SAMPLES):
        chunk[idx] = pos_code
    return chunk


def clipped_monopolar_chunk(offset: int, width: int, pos_code: int) -> list[int]:
    if offset < -width or offset >= N_CHUNK_WORDS:
        raise ValueError(f"clipped monopolar offset {offset} is outside the sweep range")
    chunk = zero_chunk()
    visible_start = max(0, offset)
    visible_end = min(N_CHUNK_WORDS, offset + width)
    for idx in range(visible_start, visible_end):
        chunk[idx] = pos_code
    return chunk


def erf_monopolar_chunk(
    offset: int,
    width: int,
    amplitude_mv: float,
    sigma_samples: float,
    adc_vfs_mv: float,
) -> list[int]:
    if offset < -width or offset >= N_CHUNK_WORDS:
        raise ValueError(f"erf monopolar offset {offset} is outside the sweep range")
    chunk = zero_chunk()
    denominator = math.sqrt(2.0) * sigma_samples
    for sample_idx in range(N_CHUNK_WORDS):
        rise = math.erf((sample_idx - offset) / denominator)
        fall = math.erf((sample_idx - (offset + width)) / denominator)
        voltage_mv = amplitude_mv * 0.5 * (rise - fall)
        chunk[sample_idx] = voltage_to_adc_code(voltage_mv, adc_vfs_mv)
    return chunk


def chunk_to_testhex_lines(chunk_ch0: list[int], pulse_channel: int) -> list[str]:
    if pulse_channel < 0 or pulse_channel > 3:
        raise ValueError("pulse_channel must be in trigger channel range 0..3")
    lines = []
    for code in chunk_ch0:
        channels = [0, 0, 0, 0]
        channels[pulse_channel] = code
        lines.append(pack_timestep(channels))
    return lines


def build_zero_case(num_samples: int, pulse_channel: int) -> StimulusCase:
    samples = [zero_chunk() for _ in range(num_samples)]
    rows = [
        {
            "sample_id": str(sample_id),
            "stim_kind": "zero",
            "pulse_offset_sample": "-1",
            "pulse_start_ns": "-1",
            "pulse_width_samples": "0",
            "pulse_peak_mv": "0.000",
            "adc_code_pos": "0",
            "adc_code_neg": "0",
            "pulse_channel": str(pulse_channel),
        }
        for sample_id in range(num_samples)
    ]
    return StimulusCase("zero", samples, rows)


def build_bipolar_sweep_case(
    pulse_mv: float,
    adc_vfs_mv: float,
    pulse_channel: int,
) -> StimulusCase:
    pos_code = voltage_to_adc_code(pulse_mv, adc_vfs_mv)
    neg_code = voltage_to_adc_code(-pulse_mv, adc_vfs_mv)
    max_offset = N_CHUNK_WORDS - PULSE_TOTAL_SAMPLES
    samples = [bipolar_chunk(offset, pos_code, neg_code) for offset in range(max_offset + 1)]
    rows = [
        {
            "sample_id": str(offset),
            "stim_kind": "bipolar_sweep",
            "pulse_offset_sample": str(offset),
            "pulse_start_ns": str(offset),
            "pulse_width_samples": str(PULSE_TOTAL_SAMPLES),
            "pulse_peak_mv": f"{pulse_mv:.3f}",
            "adc_code_pos": str(pos_code),
            "adc_code_neg": str(neg_code),
            "pulse_channel": str(pulse_channel),
        }
        for offset in range(max_offset + 1)
    ]
    return StimulusCase("bipolar_sweep", samples, rows)


def build_polar_sweep_case(
    pulse_mv: float,
    adc_vfs_mv: float,
    pulse_channel: int,
) -> StimulusCase:
    pos_code = voltage_to_adc_code(pulse_mv, adc_vfs_mv)
    max_offset = N_CHUNK_WORDS - PULSE_SEGMENT_SAMPLES
    samples = [polar_chunk(offset, pos_code) for offset in range(max_offset + 1)]
    rows = [
        {
            "sample_id": str(offset),
            "stim_kind": "polar_sweep",
            "pulse_offset_sample": str(offset),
            "pulse_start_ns": str(offset),
            "pulse_width_samples": str(PULSE_SEGMENT_SAMPLES),
            "pulse_peak_mv": f"{pulse_mv:.3f}",
            "adc_code_pos": str(pos_code),
            "adc_code_neg": "0",
            "pulse_channel": str(pulse_channel),
        }
        for offset in range(max_offset + 1)
    ]
    return StimulusCase("polar_sweep", samples, rows)


def build_monopolar_100mv_100ns_sweep_case(
    adc_vfs_mv: float,
    pulse_channel: int,
) -> StimulusCase:
    pos_code = voltage_to_adc_code(LONG_MONOPOLAR_PULSE_MV, adc_vfs_mv)
    offsets = range(-LONG_MONOPOLAR_PULSE_SAMPLES, N_CHUNK_WORDS)
    samples = [
        clipped_monopolar_chunk(offset, LONG_MONOPOLAR_PULSE_SAMPLES, pos_code)
        for offset in offsets
    ]
    rows = []
    for sample_id, offset in enumerate(offsets):
        visible_start = max(0, offset)
        visible_end = min(N_CHUNK_WORDS, offset + LONG_MONOPOLAR_PULSE_SAMPLES)
        visible_width = max(0, visible_end - visible_start)
        if offset < 0:
            truncation = "front"
        elif offset + LONG_MONOPOLAR_PULSE_SAMPLES > N_CHUNK_WORDS:
            truncation = "back"
        else:
            truncation = "none"
        rows.append({
            "sample_id": str(sample_id),
            "stim_kind": "monopolar_100mv_100ns_sweep",
            "pulse_offset_sample": str(offset),
            "pulse_start_ns": str(offset),
            "pulse_width_samples": str(LONG_MONOPOLAR_PULSE_SAMPLES),
            "visible_pulse_width_samples": str(visible_width),
            "pulse_truncation": truncation,
            "pulse_peak_mv": f"{LONG_MONOPOLAR_PULSE_MV:.3f}",
            "adc_code_pos": str(pos_code),
            "adc_code_neg": "0",
            "pulse_channel": str(pulse_channel),
        })
    return StimulusCase("monopolar_100mv_100ns_sweep", samples, rows)


def build_monopolar_100mv_100ns_erf_tr100ns_sweep_case(
    adc_vfs_mv: float,
    pulse_channel: int,
) -> StimulusCase:
    pulse_peak_mv = LONG_MONOPOLAR_PULSE_MV * math.erf(
        LONG_MONOPOLAR_PULSE_SAMPLES
        / (2.0 * math.sqrt(2.0) * ERF_EDGE_SIGMA_SAMPLES)
    )
    offsets = range(-LONG_MONOPOLAR_PULSE_SAMPLES, N_CHUNK_WORDS)
    samples = [
        erf_monopolar_chunk(
            offset,
            LONG_MONOPOLAR_PULSE_SAMPLES,
            LONG_MONOPOLAR_PULSE_MV,
            ERF_EDGE_SIGMA_SAMPLES,
            adc_vfs_mv,
        )
        for offset in offsets
    ]
    rows = []
    for sample_id, (offset, chunk) in enumerate(zip(offsets, samples)):
        nominal_start = max(0, offset)
        nominal_end = min(N_CHUNK_WORDS, offset + LONG_MONOPOLAR_PULSE_SAMPLES)
        nominal_visible_width = max(0, nominal_end - nominal_start)
        if offset < 0:
            truncation = "front"
        elif offset + LONG_MONOPOLAR_PULSE_SAMPLES > N_CHUNK_WORDS:
            truncation = "back"
        else:
            truncation = "none"
        rows.append({
            "sample_id": str(sample_id),
            "stim_kind": "monopolar_100mv_100ns_erf_tr100ns_sweep",
            "pulse_offset_sample": str(offset),
            "pulse_start_ns": str(offset),
            "pulse_width_samples": str(LONG_MONOPOLAR_PULSE_SAMPLES),
            "pulse_width_definition": "50pct_crossings",
            "nominal_visible_width_samples": str(nominal_visible_width),
            "quantized_nonzero_samples": str(sum(code != 0 for code in chunk)),
            "pulse_truncation": truncation,
            "rise_time_10_90_samples": str(ERF_EDGE_RISE_FALL_SAMPLES),
            "fall_time_90_10_samples": str(ERF_EDGE_RISE_FALL_SAMPLES),
            "gaussian_sigma_samples": f"{ERF_EDGE_SIGMA_SAMPLES:.6f}",
            "edge_model": "erf_gaussian_lowpass",
            "pulse_amplitude_parameter_mv": f"{LONG_MONOPOLAR_PULSE_MV:.3f}",
            "pulse_peak_mv": f"{pulse_peak_mv:.3f}",
            "adc_code_peak": str(voltage_to_adc_code(pulse_peak_mv, adc_vfs_mv)),
            "pulse_channel": str(pulse_channel),
        })
    return StimulusCase("monopolar_100mv_100ns_erf_tr100ns_sweep", samples, rows)


def write_case(case: StimulusCase, out_dir: Path, pulse_channel: int) -> Path:
    case_dir = out_dir / case.name
    testhex_dir = case_dir / "testhex_stream"
    testhex_dir.mkdir(parents=True, exist_ok=True)

    for sample_id, chunk in enumerate(case.samples):
        lines = chunk_to_testhex_lines(chunk, pulse_channel)
        (testhex_dir / f"test_input_sample{sample_id}.hex").write_text(
            "\n".join(lines) + "\n",
            encoding="utf-8",
        )

    (testhex_dir / "labels.hex").write_text(
        "\n".join("0" for _ in case.samples) + "\n",
        encoding="utf-8",
    )

    manifest_path = case_dir / "manifest.csv"
    with manifest_path.open("w", newline="", encoding="utf-8") as csv_file:
        fieldnames = list(case.manifest_rows[0])
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(case.manifest_rows)

    return testhex_dir


def annotate_scores(case_dir: Path) -> Path:
    manifest_path = case_dir / "manifest.csv"
    scores_path = case_dir / "scores.csv"
    out_path = case_dir / "scores_annotated.csv"

    if not manifest_path.exists():
        raise SystemExit(f"manifest not found: {manifest_path}")
    if not scores_path.exists():
        raise SystemExit(f"score CSV not found: {scores_path}")

    with manifest_path.open(newline="", encoding="utf-8") as csv_file:
        manifest_rows = list(csv.DictReader(csv_file))
    with scores_path.open(newline="", encoding="utf-8") as csv_file:
        score_rows = list(csv.DictReader(csv_file))

    manifest_by_id = {row["sample_id"]: row for row in manifest_rows}
    annotated = []
    for score_row in score_rows:
        sample_id = score_row["sample_id"]
        if sample_id not in manifest_by_id:
            raise SystemExit(f"score row sample_id={sample_id} missing from {manifest_path}")
        combined = dict(manifest_by_id[sample_id])
        for key, value in score_row.items():
            if key != "sample_id":
                combined[key] = value
        annotated.append(combined)

    if not annotated:
        raise SystemExit(f"no score rows found in {scores_path}")

    with out_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(annotated[0]))
        writer.writeheader()
        writer.writerows(annotated)

    return out_path


def selected_cases(args: argparse.Namespace) -> list[StimulusCase]:
    cases: list[StimulusCase] = []
    if args.stimulus in ("zero", "all"):
        cases.append(build_zero_case(args.num_zero_samples, args.pulse_channel))
    if args.stimulus in ("bipolar-sweep", "all"):
        cases.append(build_bipolar_sweep_case(args.pulse_mv, args.adc_vfs_mv, args.pulse_channel))
    if args.stimulus in ("polar-sweep", "all"):
        cases.append(build_polar_sweep_case(args.pulse_mv, args.adc_vfs_mv, args.pulse_channel))
    if args.stimulus in ("monopolar-100mv-100ns-sweep", "all"):
        cases.append(build_monopolar_100mv_100ns_sweep_case(args.adc_vfs_mv, args.pulse_channel))
    if args.stimulus in ("monopolar-100mv-100ns-erf-tr100ns-sweep", "all"):
        cases.append(
            build_monopolar_100mv_100ns_erf_tr100ns_sweep_case(
                args.adc_vfs_mv,
                args.pulse_channel,
            )
        )
    return cases


def run_vivado_case(args: argparse.Namespace, repo_root: Path, case: StimulusCase, testhex_dir: Path) -> int:
    case_dir = args.out_dir / case.name
    cmd = [
        sys.executable,
        str(repo_root / "scripts" / "run_vivado_sim.py"),
        "--project",
        args.project,
        "--num-samples",
        str(len(case.samples)),
        "--testhex-dir",
        str(testhex_dir),
        "--out-csv",
        str(case_dir / "scores.csv"),
        "--event-csv",
        str(case_dir / "events.csv"),
        "--score-threshold",
        str(args.score_threshold),
        "--cnn-thresh-raw",
        str(args.cnn_thresh_raw),
        "--mirror-raw-channels",
        "0",
    ]
    if args.vivado:
        cmd.extend(["--vivado", args.vivado])
    print("INFO: running:", " ".join(cmd), flush=True)
    return subprocess.call(cmd, cwd=repo_root)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate zero-input and pulse-sweep bring-up simulation stimuli."
    )
    parser.add_argument(
        "--stimulus",
        choices=(
            "zero",
            "bipolar-sweep",
            "polar-sweep",
            "monopolar-100mv-100ns-sweep",
            "monopolar-100mv-100ns-erf-tr100ns-sweep",
            "all",
        ),
        default="all",
        help="Stimulus set to generate or run. Default: all.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/bringup_sim"),
        help="Output directory for generated testhex streams and CSVs.",
    )
    parser.add_argument(
        "--generate-only",
        action="store_true",
        help="Only generate stimulus files; do not launch Vivado.",
    )
    parser.add_argument(
        "--annotate-only",
        action="store_true",
        help="Only merge existing manifest.csv and scores.csv files into scores_annotated.csv.",
    )
    parser.add_argument("--num-zero-samples", type=int, default=256)
    parser.add_argument("--pulse-mv", type=float, default=DEFAULT_PULSE_MV)
    parser.add_argument("--adc-vfs-mv", type=float, default=DEFAULT_ADC_VFS_MV)
    parser.add_argument("--pulse-channel", type=int, default=0)
    parser.add_argument("--score-threshold", type=float, default=0.0)
    parser.add_argument("--cnn-thresh-raw", type=int, default=0)
    parser.add_argument("--project", default="AI_Trigger_System/AI_Trigger_System.xpr")
    parser.add_argument("--vivado", help="Vivado executable path passed to run_vivado_sim.py.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    args.out_dir = args.out_dir.expanduser()
    if not args.out_dir.is_absolute():
        args.out_dir = repo_root / args.out_dir
    args.out_dir.mkdir(parents=True, exist_ok=True)

    if args.num_zero_samples <= 0:
        raise SystemExit("--num-zero-samples must be positive")
    if args.pulse_channel < 0 or args.pulse_channel > 3:
        raise SystemExit("--pulse-channel must be in range 0..3")

    cases = selected_cases(args)

    if args.annotate_only:
        for case in cases:
            annotated = annotate_scores(args.out_dir / case.name)
            print(f"INFO: wrote {annotated}")
        return 0

    for case in cases:
        testhex_dir = write_case(case, args.out_dir, args.pulse_channel)
        print(f"INFO: generated {case.name}: {len(case.samples)} samples -> {testhex_dir}")
        if not args.generate_only:
            result = run_vivado_case(args, repo_root, case, testhex_dir)
            if result != 0:
                return result
            annotated = annotate_scores(args.out_dir / case.name)
            print(f"INFO: wrote {annotated}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
