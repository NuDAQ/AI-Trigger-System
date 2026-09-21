#!/usr/bin/env python3
"""Behavior checks for the v3.5 Data 3 sliding-window scan."""

from __future__ import annotations

import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts import run_real_noise_scan as scan


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_real_noise_scan.py"
LAUNCHER = ROOT / "scripts" / "run_real_noise_scan.sh"
CASE_NAMES = [
    "noise_1_offset",
    "noise_2_offset",
    "noise_3_offset",
    "noise_4_offset",
    "signal_10rms_offset",
    "signal_2rms_offset",
    "signal_3rms_offset",
    "signal_4rms_offset",
]
HEALTH_LOG = (
    "Chunk overflows:  0\n"
    "ADC input overflows: 0\n"
    "Dropped triggers: 0\n"
    "Ring misses:      0\n"
)


def write_scope(path: Path, samples: int = 257) -> None:
    voltages = [0.0] * samples
    voltages[0] = 0.050
    voltages[1] = -0.050
    rows = ["x-axis,1", "second,Volt"]
    rows.extend(
        f"{(-100 + index) * 1e-9:.12e},{voltage:.12e}"
        for index, voltage in enumerate(voltages)
    )
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


class RealNoiseScanTest(unittest.TestCase):
    def test_shell_launcher_prepares_only_tracked_data3_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ai-trigger-data3-") as work:
            out_dir = Path(work) / "out"
            env = dict(os.environ)
            env["PYTHON_BIN"] = sys.executable
            env["REAL_NOISE_OUT_DIR"] = str(out_dir)
            env["REAL_NOISE_PREPARE_ONLY"] = "1"

            subprocess.run([str(LAUNCHER)], cwd=ROOT, env=env, check=True)

            self.assertEqual(
                sorted(
                    path.name
                    for path in out_dir.iterdir()
                    if path.is_dir() and (path / "manifest.csv").is_file()
                ),
                CASE_NAMES,
            )
            for case_name in CASE_NAMES:
                with (out_dir / case_name / "manifest.csv").open(
                    newline="", encoding="utf-8"
                ) as csv_file:
                    manifest = list(csv.DictReader(csv_file))
                self.assertEqual(len(manifest), 745)
                self.assertEqual(manifest[0]["window_start_ns"], "-100.000000")
                self.assertEqual(manifest[-1]["window_start_ns"], "644.000000")
                self.assertEqual(manifest[-1]["window_end_ns"], "899.000000")
                self.assertTrue((out_dir / case_name / "input_waveform.png").is_file())

            self.assertTrue((out_dir / "input_waveforms_overview.png").is_file())

            provenance = json.loads(
                (out_dir / "scan_provenance.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                provenance["dataset_root"], "data/Amp_Scope_Data_3_Offsetted"
            )
            self.assertEqual(
                [item["name"] for item in provenance["dataset_files"]],
                [f"{name}.csv" for name in CASE_NAMES],
            )
            self.assertEqual(provenance["scan"]["trigger_mode"], 2)
            self.assertTrue(provenance["scan"]["other_raw_channels_zero"])
            self.assertEqual(
                provenance["dependency_revisions"]["cnn-core"],
                "eca9b12f9f49f4b7324ed9ed241a44086ca9c842",
            )
            self.assertEqual(
                set(provenance["tool_files"]),
                {
                    "scripts/run_real_noise_scan.py",
                    "scripts/run_vivado_sim.py",
                    "run_sim.tcl",
                    "HDL/sim/tb_ai_trigger_top.sv",
                    "HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd",
                },
            )
            self.assertTrue(
                all(len(digest) == 64 for digest in provenance["tool_files"].values())
            )
            self.assertNotIn("Downloads", json.dumps(provenance))

    def test_prepare_quantizes_channel_zero_for_current_testbench(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ai-trigger-data3-small-") as work:
            work_dir = Path(work)
            input_csv = work_dir / "scope.csv"
            out_dir = work_dir / "out"
            write_scope(input_csv)

            scan.prepare_scope_csv(input_csv, out_dir, scan.DEFAULT_ADC_VFS_V)

            case_dir = out_dir / "scope"
            sample0 = (
                case_dir / "testhex_stream" / "test_input_sample0.hex"
            ).read_text(encoding="utf-8").splitlines()
            sample1 = (
                case_dir / "testhex_stream" / "test_input_sample1.hex"
            ).read_text(encoding="utf-8").splitlines()
            labels = (case_dir / "testhex_stream" / "labels.hex").read_text(
                encoding="utf-8"
            ).splitlines()

            self.assertEqual(len(sample0), 256)
            self.assertEqual(sample0[:3], [
                "0000000000000100",
                "0000000000000f00",
                "0000000000000000",
            ])
            self.assertEqual(sample1[:2], [
                "0000000000000f00",
                "0000000000000000",
            ])
            self.assertEqual(labels, ["0", "0"])

    def test_loader_rejects_download_format_header(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ai-trigger-data3-header-") as work:
            work_dir = Path(work)
            input_csv = work_dir / "scope.csv"
            input_csv.write_text(
                "Time,CH1\n"
                + "\n".join(f"{index * 1e-9:.12e},0.0" for index in range(256))
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "expected 'x-axis,1'"):
                scan.load_scope_csv(input_csv)

    def test_full_cli_uses_current_v35_interface_and_writes_plots(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ai-trigger-data3-full-") as work:
            work_dir = Path(work)
            out_dir = work_dir / "out"
            captured_args = work_dir / "runner_args.json"
            xsim_log = work_dir / "simulate.log"
            fake_runner = work_dir / "fake_runner.py"
            stale_case = out_dir / "not_selected"
            stale_case.mkdir(parents=True)
            (stale_case / "manifest.csv").write_text(
                "sample_id,source_file\n0,not_selected.csv\n", encoding="utf-8"
            )
            xsim_log.write_text(HEALTH_LOG, encoding="utf-8")
            fake_runner.write_text(
                """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
Path(os.environ["CAPTURED_ARGS"]).write_text(json.dumps(args), encoding="utf-8")
count = int(args[args.index("--num-samples") + 1])
out_csv = Path(args[args.index("--out-csv") + 1])
event_csv = Path(args[args.index("--event-csv") + 1])
rows = ["sample_id,hex_out,float_out,label,prediction,correct,latency_cycles_cnn,latency_us"]
for sample_id in range(count):
    score = -0.5 if sample_id == 0 else 1.5
    rows.append(f"{sample_id},0x00000000,{score:.6f},0,0,1,200,1.000")
out_csv.write_text("\\n".join(rows) + "\\n", encoding="utf-8")
event_csv.write_text("event_index,event_chunk_id\\n", encoding="utf-8")
""",
                encoding="utf-8",
            )
            env = dict(os.environ)
            env["CAPTURED_ARGS"] = str(captured_args)

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--case",
                    "noise_1_offset",
                    "--out-dir",
                    str(out_dir),
                    "--sim-runner",
                    str(fake_runner),
                    "--xsim-log",
                    str(xsim_log),
                    "--cnn-thresh-raw",
                    "16",
                ],
                cwd=ROOT,
                env=env,
                check=True,
            )

            runner_args = json.loads(captured_args.read_text(encoding="utf-8"))
            self.assertEqual(
                runner_args[runner_args.index("--trigger-mode") + 1], "2"
            )
            self.assertEqual(
                runner_args[runner_args.index("--mirror-raw-channels") + 1], "0"
            )
            self.assertEqual(
                runner_args[runner_args.index("--cnn-thresh-raw") + 1], "16"
            )
            self.assertEqual(
                runner_args[runner_args.index("--score-threshold") + 1], "1.0"
            )
            self.assertNotIn("--pace-chunks", runner_args)

            with (out_dir / "offset_scan_summary.csv").open(
                newline="", encoding="utf-8"
            ) as csv_file:
                summary = list(csv.DictReader(csv_file))
            self.assertEqual(summary[0]["window_count"], "745")
            self.assertEqual(summary[0]["score_threshold"], "1.000000")
            self.assertEqual(summary[0]["triggered_windows"], "744")
            self.assertTrue(
                (out_dir / "offset_score_vs_window_start_overlay.png").exists()
            )
            self.assertTrue(
                (out_dir / "offset_score_histogram_overlay.png").exists()
            )

    def test_analyze_rejects_nonzero_current_system_health_counter(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ai-trigger-data3-health-") as work:
            work_dir = Path(work)
            input_csv = work_dir / "noise_1_offset.csv"
            out_dir = work_dir / "out"
            write_scope(input_csv, samples=256)
            scan.prepare_scope_csv(input_csv, out_dir, scan.DEFAULT_ADC_VFS_V)
            case_dir = out_dir / "noise_1_offset"
            (case_dir / "scores.csv").write_text(
                "sample_id,float_out\n0,-0.25\n", encoding="utf-8"
            )
            (case_dir / "simulate.log").write_text(
                HEALTH_LOG.replace("Chunk overflows:  0", "Chunk overflows:  1"),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--analyze-only",
                    "--out-dir",
                    str(out_dir),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Chunk overflows=1", result.stderr + result.stdout)
            self.assertFalse((case_dir / "scores_annotated.csv").exists())

    def test_threshold_word_must_fit_current_signed_32_bit_interface(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--cnn-thresh-raw",
                str(1 << 31),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed 32-bit v3.5 interface", result.stderr + result.stdout)

    def test_scan_never_depends_on_downloads(self) -> None:
        self.assertNotIn("/Users/albert/Downloads", SCRIPT.read_text(encoding="utf-8"))
        self.assertNotIn("/Users/albert/Downloads", LAUNCHER.read_text(encoding="utf-8"))

    def test_git_tracks_results_but_ignores_generated_stimuli(self) -> None:
        for relative in (
            "build/real_noise_scan/scan_provenance.json",
            "build/real_noise_scan/offset_scan_summary.csv",
            "build/real_noise_scan/noise_1_offset/scores.csv",
            "build/real_noise_scan/noise_1_offset/score_histogram.png",
            "build/real_noise_scan/noise_1_offset/simulate.log",
        ):
            result = subprocess.run(
                ["git", "check-ignore", "--no-index", relative],
                cwd=ROOT,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 1, msg=f"expected trackable: {relative}")

        stimulus = subprocess.run(
            [
                "git",
                "check-ignore",
                "--no-index",
                "build/real_noise_scan/noise_1_offset/testhex_stream/sample.hex",
            ],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(stimulus.returncode, 0)


if __name__ == "__main__":
    unittest.main()
