#!/usr/bin/env python3
"""Behavior checks for DAQ bring-up simulation stimulus generation."""

from __future__ import annotations

import csv
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_bringup_sim.py"


class BringupSimulationTest(unittest.TestCase):
    def run_generate(self, *args: str) -> Path:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-bringup-"))
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--generate-only",
                "--out-dir",
                str(out_dir),
                *args,
            ],
            cwd=ROOT,
            check=True,
        )
        return out_dir

    def test_bipolar_sweep_generates_ch0_only_50mv_pulse_manifest(self) -> None:
        out_dir = self.run_generate("--stimulus", "bipolar-sweep")

        testhex_dir = out_dir / "bipolar_sweep" / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        with (out_dir / "bipolar_sweep" / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))
        sample0 = (testhex_dir / "test_input_sample0.hex").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(labels), 247)
        self.assertTrue(all(label == "0" for label in labels))
        self.assertEqual(len(manifest_rows), 247)
        self.assertEqual(manifest_rows[0]["stim_kind"], "bipolar_sweep")
        self.assertEqual(manifest_rows[0]["pulse_offset_sample"], "0")
        self.assertEqual(manifest_rows[-1]["pulse_offset_sample"], "246")
        self.assertEqual(manifest_rows[0]["pulse_width_samples"], "10")
        self.assertEqual(manifest_rows[0]["pulse_peak_mv"], "50.000")
        self.assertEqual(manifest_rows[0]["adc_code_pos"], "256")
        self.assertEqual(manifest_rows[0]["adc_code_neg"], "-256")
        self.assertEqual(manifest_rows[0]["pulse_channel"], "0")

        self.assertEqual(len(sample0), 256)
        self.assertEqual(sample0[0:5], ["0000000000000100"] * 5)
        self.assertEqual(sample0[5:10], ["0000000000000f00"] * 5)
        self.assertEqual(sample0[10:], ["0000000000000000"] * (256 - 10))

    def test_polar_sweep_generates_ch0_only_positive_50mv_pulse_manifest(self) -> None:
        out_dir = self.run_generate("--stimulus", "polar-sweep")

        testhex_dir = out_dir / "polar_sweep" / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        with (out_dir / "polar_sweep" / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))
        sample0 = (testhex_dir / "test_input_sample0.hex").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(labels), 252)
        self.assertTrue(all(label == "0" for label in labels))
        self.assertEqual(len(manifest_rows), 252)
        self.assertEqual(manifest_rows[0]["stim_kind"], "polar_sweep")
        self.assertEqual(manifest_rows[0]["pulse_offset_sample"], "0")
        self.assertEqual(manifest_rows[-1]["pulse_offset_sample"], "251")
        self.assertEqual(manifest_rows[0]["pulse_width_samples"], "5")
        self.assertEqual(manifest_rows[0]["pulse_peak_mv"], "50.000")
        self.assertEqual(manifest_rows[0]["adc_code_pos"], "256")
        self.assertEqual(manifest_rows[0]["adc_code_neg"], "0")
        self.assertEqual(manifest_rows[0]["pulse_channel"], "0")

        self.assertEqual(len(sample0), 256)
        self.assertEqual(sample0[0:5], ["0000000000000100"] * 5)
        self.assertEqual(sample0[5:], ["0000000000000000"] * (256 - 5))

    def test_monopolar_100mv_100ns_sweep_clips_at_both_chunk_edges(self) -> None:
        out_dir = self.run_generate("--stimulus", "monopolar-100mv-100ns-sweep")

        case_dir = out_dir / "monopolar_100mv_100ns_sweep"
        testhex_dir = case_dir / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        with (case_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))

        self.assertEqual(len(labels), 356)
        self.assertTrue(all(label == "0" for label in labels))
        self.assertEqual(len(manifest_rows), 356)
        self.assertEqual(manifest_rows[0]["sample_id"], "0")
        self.assertEqual(manifest_rows[0]["pulse_offset_sample"], "-100")
        self.assertEqual(manifest_rows[0]["visible_pulse_width_samples"], "0")
        self.assertEqual(manifest_rows[0]["pulse_truncation"], "front")
        self.assertEqual(manifest_rows[1]["pulse_offset_sample"], "-99")
        self.assertEqual(manifest_rows[1]["visible_pulse_width_samples"], "1")
        self.assertEqual(manifest_rows[99]["pulse_offset_sample"], "-1")
        self.assertEqual(manifest_rows[99]["visible_pulse_width_samples"], "99")
        self.assertEqual(manifest_rows[100]["pulse_offset_sample"], "0")
        self.assertEqual(manifest_rows[100]["visible_pulse_width_samples"], "100")
        self.assertEqual(manifest_rows[100]["pulse_truncation"], "none")
        self.assertEqual(manifest_rows[256]["pulse_offset_sample"], "156")
        self.assertEqual(manifest_rows[256]["visible_pulse_width_samples"], "100")
        self.assertEqual(manifest_rows[257]["pulse_offset_sample"], "157")
        self.assertEqual(manifest_rows[257]["visible_pulse_width_samples"], "99")
        self.assertEqual(manifest_rows[257]["pulse_truncation"], "back")
        self.assertEqual(manifest_rows[-1]["sample_id"], "355")
        self.assertEqual(manifest_rows[-1]["pulse_offset_sample"], "255")
        self.assertEqual(manifest_rows[-1]["visible_pulse_width_samples"], "1")
        self.assertEqual(manifest_rows[100]["pulse_width_samples"], "100")
        self.assertEqual(manifest_rows[100]["pulse_peak_mv"], "100.000")
        self.assertEqual(manifest_rows[100]["adc_code_pos"], "512")
        self.assertEqual(manifest_rows[100]["adc_code_neg"], "0")
        self.assertEqual(manifest_rows[100]["pulse_channel"], "0")

        zero_sample = (testhex_dir / "test_input_sample0.hex").read_text(encoding="utf-8").splitlines()
        front_sample = (testhex_dir / "test_input_sample50.hex").read_text(encoding="utf-8").splitlines()
        full_sample = (testhex_dir / "test_input_sample100.hex").read_text(encoding="utf-8").splitlines()
        back_sample = (testhex_dir / "test_input_sample300.hex").read_text(encoding="utf-8").splitlines()
        final_sample = (testhex_dir / "test_input_sample355.hex").read_text(encoding="utf-8").splitlines()

        self.assertEqual(set(zero_sample), {"0000000000000000"})
        self.assertEqual(front_sample[:50], ["0000000000000200"] * 50)
        self.assertEqual(front_sample[50:], ["0000000000000000"] * 206)
        self.assertEqual(full_sample[:100], ["0000000000000200"] * 100)
        self.assertEqual(full_sample[100:], ["0000000000000000"] * 156)
        self.assertEqual(back_sample[:200], ["0000000000000000"] * 200)
        self.assertEqual(back_sample[200:], ["0000000000000200"] * 56)
        self.assertEqual(final_sample[:255], ["0000000000000000"] * 255)
        self.assertEqual(final_sample[255], "0000000000000200")

    def test_monopolar_100mv_100ns_erf_tr100ns_sweep_has_overlapping_edges(self) -> None:
        out_dir = self.run_generate("--stimulus", "monopolar-100mv-100ns-erf-tr100ns-sweep")

        case_dir = out_dir / "monopolar_100mv_100ns_erf_tr100ns_sweep"
        testhex_dir = case_dir / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        with (case_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))

        self.assertEqual(len(labels), 356)
        self.assertEqual(len(manifest_rows), 356)
        self.assertEqual(manifest_rows[0]["sample_id"], "0")
        self.assertEqual(manifest_rows[0]["pulse_offset_sample"], "-100")
        self.assertEqual(manifest_rows[0]["nominal_visible_width_samples"], "0")
        self.assertEqual(manifest_rows[0]["quantized_nonzero_samples"], "121")
        self.assertEqual(manifest_rows[0]["pulse_truncation"], "front")
        self.assertEqual(manifest_rows[100]["pulse_offset_sample"], "0")
        self.assertEqual(manifest_rows[100]["nominal_visible_width_samples"], "100")
        self.assertEqual(manifest_rows[100]["quantized_nonzero_samples"], "221")
        self.assertEqual(manifest_rows[100]["pulse_truncation"], "none")
        self.assertEqual(manifest_rows[256]["pulse_offset_sample"], "156")
        self.assertEqual(manifest_rows[256]["nominal_visible_width_samples"], "100")
        self.assertEqual(manifest_rows[256]["quantized_nonzero_samples"], "220")
        self.assertEqual(manifest_rows[-1]["sample_id"], "355")
        self.assertEqual(manifest_rows[-1]["pulse_offset_sample"], "255")
        self.assertEqual(manifest_rows[-1]["nominal_visible_width_samples"], "1")
        self.assertEqual(manifest_rows[-1]["quantized_nonzero_samples"], "121")
        self.assertEqual(manifest_rows[-1]["pulse_truncation"], "back")
        self.assertEqual(manifest_rows[100]["pulse_width_samples"], "100")
        self.assertEqual(manifest_rows[100]["pulse_width_definition"], "50pct_crossings")
        self.assertEqual(manifest_rows[100]["rise_time_10_90_samples"], "100")
        self.assertEqual(manifest_rows[100]["fall_time_90_10_samples"], "100")
        self.assertEqual(manifest_rows[100]["gaussian_sigma_samples"], "39.016777")
        self.assertEqual(manifest_rows[100]["edge_model"], "erf_gaussian_lowpass")
        self.assertEqual(manifest_rows[100]["pulse_amplitude_parameter_mv"], "100.000")
        self.assertEqual(manifest_rows[100]["pulse_peak_mv"], "79.998")
        self.assertEqual(manifest_rows[100]["adc_code_peak"], "410")

        front_sample = (testhex_dir / "test_input_sample0.hex").read_text(encoding="utf-8").splitlines()
        centered_sample = (testhex_dir / "test_input_sample100.hex").read_text(encoding="utf-8").splitlines()
        back_sample = (testhex_dir / "test_input_sample355.hex").read_text(encoding="utf-8").splitlines()

        self.assertEqual(front_sample[0], "00000000000000fd")
        self.assertEqual(front_sample[5], "00000000000000e4")
        self.assertEqual(front_sample[10], "00000000000000cb")
        self.assertEqual(centered_sample[0], "00000000000000fd")
        self.assertEqual(centered_sample[10], "000000000000012e")
        self.assertEqual(centered_sample[25], "000000000000016c")
        self.assertEqual(centered_sample[50], "000000000000019a")
        self.assertEqual(centered_sample[75], "000000000000016c")
        self.assertEqual(centered_sample[90], "000000000000012e")
        self.assertEqual(centered_sample[100], "00000000000000fd")
        self.assertEqual(centered_sample[150], "0000000000000033")
        self.assertEqual(centered_sample[200], "0000000000000003")
        self.assertEqual(centered_sample[250], "0000000000000000")
        self.assertEqual(back_sample[245], "00000000000000cb")
        self.assertEqual(back_sample[250], "00000000000000e4")
        self.assertEqual(back_sample[254], "00000000000000f8")
        self.assertEqual(back_sample[255], "00000000000000fd")

    def test_zero_stimulus_generates_all_zero_chunks(self) -> None:
        out_dir = self.run_generate("--stimulus", "zero", "--num-zero-samples", "3")

        testhex_dir = out_dir / "zero" / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        sample2 = (testhex_dir / "test_input_sample2.hex").read_text(encoding="utf-8").splitlines()
        with (out_dir / "zero" / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))

        self.assertEqual(labels, ["0", "0", "0"])
        self.assertEqual(len(sample2), 256)
        self.assertEqual(set(sample2), {"0000000000000000"})
        self.assertEqual([row["stim_kind"] for row in manifest_rows], ["zero", "zero", "zero"])
        self.assertEqual([row["pulse_offset_sample"] for row in manifest_rows], ["-1", "-1", "-1"])

    def test_bringup_runner_disables_raw_channel_mirroring(self) -> None:
        testbench = (ROOT / "HDL" / "sim" / "tb_ai_trigger_top.sv").read_text(encoding="utf-8")
        run_sim_tcl = (ROOT / "run_sim.tcl").read_text(encoding="utf-8")
        run_vivado_sim = (ROOT / "scripts" / "run_vivado_sim.py").read_text(encoding="utf-8")
        bringup_runner = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("MIRROR_RAW_CHANNELS", testbench)
        self.assertIn("RUN_SIM_MIRROR_RAW_CHANNELS", run_sim_tcl)
        self.assertIn("--mirror-raw-channels", run_vivado_sim)
        self.assertIn('"--mirror-raw-channels"', bringup_runner)
        self.assertIn('"0"', bringup_runner)

    def test_launcher_generate_only_builds_all_named_bringup_cases(self) -> None:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-bringup-launcher-"))
        env = dict(os.environ)
        env["BRINGUP_OUT_DIR"] = str(out_dir)
        env["BRINGUP_GENERATE_ONLY"] = "1"
        env["PYTHON_BIN"] = sys.executable

        result = subprocess.run(
            [str(ROOT / "scripts" / "run_bringup_pulse_sweeps.sh")],
            cwd=ROOT,
            env=env,
            check=True,
            text=True,
            capture_output=True,
        )

        self.assertEqual(
            sorted(path.name for path in out_dir.iterdir() if path.is_dir()),
            [
                "bipolar_sweep",
                "monopolar_100mv_100ns_erf_tr100ns_sweep",
                "monopolar_100mv_100ns_sweep",
                "polar_sweep",
                "zero",
            ],
        )
        self.assertEqual(
            len((out_dir / "monopolar_100mv_100ns_sweep" / "testhex_stream" / "labels.hex").read_text(encoding="utf-8").splitlines()),
            356,
        )
        self.assertIn("monopolar_100mv_100ns_erf_tr100ns_sweep", result.stdout)
        self.assertIn("generate-only: skipping score plotting", result.stdout)

    def test_annotate_and_plot_scores_from_vivado_csv(self) -> None:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-bringup-results-"))
        zero_dir = out_dir / "zero"
        bipolar_dir = out_dir / "bipolar_sweep"
        polar_dir = out_dir / "polar_sweep"
        long_monopolar_dir = out_dir / "monopolar_100mv_100ns_sweep"
        erf_monopolar_dir = out_dir / "monopolar_100mv_100ns_erf_tr100ns_sweep"
        zero_dir.mkdir(parents=True)
        bipolar_dir.mkdir(parents=True)
        polar_dir.mkdir(parents=True)
        long_monopolar_dir.mkdir(parents=True)
        erf_monopolar_dir.mkdir(parents=True)

        self.write_manifest(zero_dir / "manifest.csv", [
            {"sample_id": "0", "stim_kind": "zero", "pulse_offset_sample": "-1", "pulse_start_ns": "-1", "pulse_width_samples": "0", "pulse_peak_mv": "0.000", "adc_code_pos": "0", "adc_code_neg": "0", "pulse_channel": "0"},
            {"sample_id": "1", "stim_kind": "zero", "pulse_offset_sample": "-1", "pulse_start_ns": "-1", "pulse_width_samples": "0", "pulse_peak_mv": "0.000", "adc_code_pos": "0", "adc_code_neg": "0", "pulse_channel": "0"},
        ])
        self.write_manifest(bipolar_dir / "manifest.csv", [
            {"sample_id": "0", "stim_kind": "bipolar_sweep", "pulse_offset_sample": "0", "pulse_start_ns": "0", "pulse_width_samples": "10", "pulse_peak_mv": "50.000", "adc_code_pos": "256", "adc_code_neg": "-256", "pulse_channel": "0"},
            {"sample_id": "1", "stim_kind": "bipolar_sweep", "pulse_offset_sample": "1", "pulse_start_ns": "1", "pulse_width_samples": "10", "pulse_peak_mv": "50.000", "adc_code_pos": "256", "adc_code_neg": "-256", "pulse_channel": "0"},
        ])
        self.write_manifest(polar_dir / "manifest.csv", [
            {"sample_id": "0", "stim_kind": "polar_sweep", "pulse_offset_sample": "0", "pulse_start_ns": "0", "pulse_width_samples": "5", "pulse_peak_mv": "50.000", "adc_code_pos": "256", "adc_code_neg": "0", "pulse_channel": "0"},
            {"sample_id": "1", "stim_kind": "polar_sweep", "pulse_offset_sample": "1", "pulse_start_ns": "1", "pulse_width_samples": "5", "pulse_peak_mv": "50.000", "adc_code_pos": "256", "adc_code_neg": "0", "pulse_channel": "0"},
        ])
        self.write_manifest(long_monopolar_dir / "manifest.csv", [
            {"sample_id": "0", "stim_kind": "monopolar_100mv_100ns_sweep", "pulse_offset_sample": "-100", "pulse_start_ns": "-100", "pulse_width_samples": "100", "visible_pulse_width_samples": "0", "pulse_truncation": "front", "pulse_peak_mv": "100.000", "adc_code_pos": "512", "adc_code_neg": "0", "pulse_channel": "0"},
            {"sample_id": "1", "stim_kind": "monopolar_100mv_100ns_sweep", "pulse_offset_sample": "0", "pulse_start_ns": "0", "pulse_width_samples": "100", "visible_pulse_width_samples": "100", "pulse_truncation": "none", "pulse_peak_mv": "100.000", "adc_code_pos": "512", "adc_code_neg": "0", "pulse_channel": "0"},
            {"sample_id": "2", "stim_kind": "monopolar_100mv_100ns_sweep", "pulse_offset_sample": "255", "pulse_start_ns": "255", "pulse_width_samples": "100", "visible_pulse_width_samples": "1", "pulse_truncation": "back", "pulse_peak_mv": "100.000", "adc_code_pos": "512", "adc_code_neg": "0", "pulse_channel": "0"},
        ])
        self.write_manifest(erf_monopolar_dir / "manifest.csv", [
            {"sample_id": "0", "stim_kind": "monopolar_100mv_100ns_erf_tr100ns_sweep", "pulse_offset_sample": "-100", "pulse_start_ns": "-100", "pulse_width_samples": "100", "pulse_width_definition": "50pct_crossings", "nominal_visible_width_samples": "0", "quantized_nonzero_samples": "121", "pulse_truncation": "front", "rise_time_10_90_samples": "100", "fall_time_90_10_samples": "100", "gaussian_sigma_samples": "39.016777", "edge_model": "erf_gaussian_lowpass", "pulse_amplitude_parameter_mv": "100.000", "pulse_peak_mv": "79.998", "adc_code_peak": "410", "pulse_channel": "0"},
            {"sample_id": "1", "stim_kind": "monopolar_100mv_100ns_erf_tr100ns_sweep", "pulse_offset_sample": "0", "pulse_start_ns": "0", "pulse_width_samples": "100", "pulse_width_definition": "50pct_crossings", "nominal_visible_width_samples": "100", "quantized_nonzero_samples": "221", "pulse_truncation": "none", "rise_time_10_90_samples": "100", "fall_time_90_10_samples": "100", "gaussian_sigma_samples": "39.016777", "edge_model": "erf_gaussian_lowpass", "pulse_amplitude_parameter_mv": "100.000", "pulse_peak_mv": "79.998", "adc_code_peak": "410", "pulse_channel": "0"},
            {"sample_id": "2", "stim_kind": "monopolar_100mv_100ns_erf_tr100ns_sweep", "pulse_offset_sample": "255", "pulse_start_ns": "255", "pulse_width_samples": "100", "pulse_width_definition": "50pct_crossings", "nominal_visible_width_samples": "1", "quantized_nonzero_samples": "121", "pulse_truncation": "back", "rise_time_10_90_samples": "100", "fall_time_90_10_samples": "100", "gaussian_sigma_samples": "39.016777", "edge_model": "erf_gaussian_lowpass", "pulse_amplitude_parameter_mv": "100.000", "pulse_peak_mv": "79.998", "adc_code_peak": "410", "pulse_channel": "0"},
        ])
        self.write_scores(zero_dir / "scores.csv", [("0", "-1.000000"), ("1", "-1.250000")])
        self.write_scores(bipolar_dir / "scores.csv", [("0", "0.500000"), ("1", "0.750000")])
        self.write_scores(polar_dir / "scores.csv", [("0", "1.500000"), ("1", "1.750000")])
        self.write_scores(long_monopolar_dir / "scores.csv", [("0", "-1.000000"), ("1", "2.500000"), ("2", "0.250000")])
        self.write_scores(erf_monopolar_dir / "scores.csv", [("0", "-0.750000"), ("1", "2.250000"), ("2", "0.500000")])

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--annotate-only",
                "--stimulus",
                "all",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "plot_bringup_scores.py"),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        with (zero_dir / "scores_annotated.csv").open(newline="", encoding="utf-8") as csv_file:
            zero_rows = list(csv.DictReader(csv_file))
        with (bipolar_dir / "scores_annotated.csv").open(newline="", encoding="utf-8") as csv_file:
            bipolar_rows = list(csv.DictReader(csv_file))
        with (polar_dir / "scores_annotated.csv").open(newline="", encoding="utf-8") as csv_file:
            polar_rows = list(csv.DictReader(csv_file))
        with (long_monopolar_dir / "scores_annotated.csv").open(newline="", encoding="utf-8") as csv_file:
            long_monopolar_rows = list(csv.DictReader(csv_file))
        with (erf_monopolar_dir / "scores_annotated.csv").open(newline="", encoding="utf-8") as csv_file:
            erf_monopolar_rows = list(csv.DictReader(csv_file))
        with (out_dir / "bringup_score_summary.csv").open(newline="", encoding="utf-8") as csv_file:
            summary_rows = list(csv.DictReader(csv_file))

        self.assertEqual(zero_rows[0]["stim_kind"], "zero")
        self.assertEqual(zero_rows[0]["float_out"], "-1.000000")
        self.assertEqual(bipolar_rows[1]["pulse_offset_sample"], "1")
        self.assertEqual(bipolar_rows[1]["float_out"], "0.750000")
        self.assertEqual(polar_rows[1]["pulse_offset_sample"], "1")
        self.assertEqual(polar_rows[1]["float_out"], "1.750000")
        self.assertEqual(long_monopolar_rows[0]["pulse_offset_sample"], "-100")
        self.assertEqual(long_monopolar_rows[2]["visible_pulse_width_samples"], "1")
        self.assertEqual(long_monopolar_rows[1]["float_out"], "2.500000")
        self.assertEqual(erf_monopolar_rows[0]["quantized_nonzero_samples"], "121")
        self.assertEqual(erf_monopolar_rows[1]["float_out"], "2.250000")
        self.assertEqual(
            [row["stim_kind"] for row in summary_rows],
            [
                "zero",
                "bipolar_sweep",
                "polar_sweep",
                "monopolar_100mv_100ns_sweep",
                "monopolar_100mv_100ns_erf_tr100ns_sweep",
            ],
        )
        self.assertTrue((out_dir / "score_vs_offset.png").exists())
        self.assertTrue((out_dir / "polar_score_vs_offset.png").exists())
        self.assertTrue((out_dir / "monopolar_100mv_100ns_score_vs_offset.png").exists())
        self.assertTrue((out_dir / "monopolar_100mv_100ns_erf_tr100ns_score_vs_offset.png").exists())
        self.assertTrue((out_dir / "score_histogram.png").exists())
        self.assertTrue((out_dir / "bringup_score_summary.csv").exists())

    @staticmethod
    def write_manifest(path: Path, rows: list[dict[str, str]]) -> None:
        with path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)

    @staticmethod
    def write_scores(path: Path, rows: list[tuple[str, str]]) -> None:
        with path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(
                csv_file,
                fieldnames=[
                    "sample_id",
                    "hex_out",
                    "float_out",
                    "label",
                    "prediction",
                    "correct",
                    "latency_cycles_cnn",
                    "latency_us",
                ],
            )
            writer.writeheader()
            for sample_id, score in rows:
                writer.writerow({
                    "sample_id": sample_id,
                    "hex_out": "0x00000000",
                    "float_out": score,
                    "label": "0",
                    "prediction": "0",
                    "correct": "1",
                    "latency_cycles_cnn": "200",
                    "latency_us": "1.000",
                })


if __name__ == "__main__":
    unittest.main()
