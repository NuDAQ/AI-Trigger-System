#!/usr/bin/env python3
"""Public CLI behavior checks for the real-noise sliding-window scan."""

from __future__ import annotations

import csv
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_real_noise_scan.py"


class RealNoiseScanTest(unittest.TestCase):
    def test_shell_launcher_prepares_all_default_scope_files(self) -> None:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-launcher-"))
        env = dict(os.environ)
        env["PYTHON_BIN"] = sys.executable
        env["REAL_NOISE_OUT_DIR"] = str(out_dir)
        env["REAL_NOISE_PREPARE_ONLY"] = "1"

        subprocess.run(
            [str(ROOT / "scripts" / "run_real_noise_scan.sh")],
            cwd=ROOT,
            env=env,
            check=True,
        )

        self.assertEqual(
            sorted(path.name for path in out_dir.iterdir() if path.is_dir()),
            ["signal_10", "signal_2", "signal_3", "signal_4"],
        )

    def test_prepare_cli_slides_complete_windows_and_quantizes_scope_volts(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        voltages = [0.0] * 257
        voltages[0] = 0.050
        voltages[1] = -0.050
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(
            f"{(-100 + sample_index) * 1e-9:.12e},{voltage:.12e}"
            for sample_index, voltage in enumerate(voltages)
        )
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        case_dir = out_dir / "scope"
        with (case_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest = list(csv.DictReader(csv_file))
        sample0 = (
            case_dir / "testhex_stream" / "test_input_sample0.hex"
        ).read_text(encoding="utf-8").splitlines()
        sample1 = (
            case_dir / "testhex_stream" / "test_input_sample1.hex"
        ).read_text(encoding="utf-8").splitlines()
        labels = (case_dir / "testhex_stream" / "labels.hex").read_text(
            encoding="utf-8"
        ).splitlines()

        self.assertEqual(len(manifest), 2)
        self.assertEqual(
            [row["window_start_ns"] for row in manifest],
            ["-100.000000", "-99.000000"],
        )
        self.assertEqual(
            [row["window_end_ns"] for row in manifest],
            ["155.000000", "156.000000"],
        )
        self.assertEqual([row["source_file"] for row in manifest], ["scope.csv"] * 2)
        self.assertEqual(labels, ["0", "0"])
        self.assertEqual(len(sample0), 256)
        self.assertEqual(len(sample1), 256)
        self.assertEqual(sample0[:3], [
            "0000000000000100",
            "0000000000000f00",
            "0000000000000000",
        ])
        self.assertEqual(sample1[:2], [
            "0000000000000f00",
            "0000000000000000",
        ])

    def test_prepare_cli_discovers_all_scope_files_and_writes_745_windows_each(self) -> None:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-data-"))

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        self.assertEqual(
            sorted(path.name for path in out_dir.iterdir() if path.is_dir()),
            ["signal_10", "signal_2", "signal_3", "signal_4"],
        )
        for case_name in ("signal_10", "signal_2", "signal_3", "signal_4"):
            with (out_dir / case_name / "manifest.csv").open(
                newline="", encoding="utf-8"
            ) as csv_file:
                manifest = list(csv.DictReader(csv_file))
            self.assertEqual(len(manifest), 745)
            self.assertEqual(manifest[0]["window_start_ns"], "-100.000000")
            self.assertEqual(manifest[-1]["window_start_ns"], "644.000000")
            self.assertEqual(manifest[-1]["window_end_ns"], "899.000000")

    def test_prepare_cli_rejects_scope_data_without_one_ns_spacing(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-spacing-"))
        input_csv = work_dir / "bad_spacing.csv"
        out_dir = work_dir / "out"
        rows = ["x-axis,1", "second,Volt"]
        for sample_index in range(256):
            time_ns = -100 + sample_index
            if sample_index == 128:
                time_ns += 0.5
            rows.append(f"{time_ns * 1e-9:.12e},0.0")
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 ns sample spacing", result.stderr)

    def test_prepare_cli_records_adc_conversion_and_saturation(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-adc-"))
        input_csv = work_dir / "saturation.csv"
        out_dir = work_dir / "out"
        voltages = [0.0] * 256
        voltages[0] = -0.500
        voltages[1] = 0.500
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(
            f"{sample_index * 1e-9:.12e},{voltage:.12e}"
            for sample_index, voltage in enumerate(voltages)
        )
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        with (out_dir / "saturation" / "manifest.csv").open(
            newline="", encoding="utf-8"
        ) as csv_file:
            manifest_row = next(csv.DictReader(csv_file))
        sample = (
            out_dir / "saturation" / "testhex_stream" / "test_input_sample0.hex"
        ).read_text(encoding="utf-8").splitlines()

        self.assertEqual(sample[:2], ["0000000000000800", "00000000000007ff"])
        self.assertEqual(manifest_row["adc_vfs_v"], "0.800000")
        self.assertEqual(manifest_row["adc_code_min"], "-2048")
        self.assertEqual(manifest_row["adc_code_max"], "2047")
        self.assertEqual(manifest_row["adc_saturated_samples"], "2")

    def test_full_cli_invokes_simulation_with_single_inflight_pacing(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-runner-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        captured_args = work_dir / "runner_args.txt"
        fake_runner = work_dir / "fake_runner.py"
        xsim_log = work_dir / "simulate.log"
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(f"{sample_index * 1e-9:.12e},0.0" for sample_index in range(256))
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")
        fake_runner.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "from pathlib import Path",
                    "import sys",
                    "def arg_value(name):",
                    "    return sys.argv[sys.argv.index(name) + 1]",
                    f"Path({str(captured_args)!r}).write_text('\\n'.join(sys.argv[1:]) + '\\n')",
                    "Path(arg_value('--out-csv')).write_text('sample_id,float_out\\n0,-1.000000\\n')",
                    "Path(arg_value('--event-csv')).write_text('event_chunk_id,event_batch_index\\n')",
                    f"Path({str(xsim_log)!r}).write_text("
                    "'Chunk overflows:  0\\nADC input overflows: 0\\n'"
                    "'Dropped triggers: 0\\nRing misses:      0\\n')",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
                "--sim-runner",
                str(fake_runner),
                "--xsim-log",
                str(xsim_log),
            ],
            cwd=ROOT,
            check=True,
        )

        runner_args = captured_args.read_text(encoding="utf-8").splitlines()
        self.assertEqual(runner_args[runner_args.index("--num-samples") + 1], "1")
        self.assertEqual(runner_args[runner_args.index("--pace-chunks") + 1], "1")
        self.assertEqual(
            runner_args[runner_args.index("--testhex-dir") + 1],
            str((out_dir / "scope" / "testhex_stream").resolve()),
        )
        self.assertEqual(runner_args[runner_args.index("--mirror-raw-channels") + 1], "0")
        self.assertTrue((out_dir / "scope" / "simulate.log").exists())
        self.assertTrue((out_dir / "scan_summary.csv").exists())

    def test_vivado_runner_forwards_pacing_to_xsim(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-xsim-"))
        project = work_dir / "dummy.xpr"
        fake_vivado = work_dir / "fake_vivado.py"
        captured_tcl = work_dir / "captured.tcl"
        project.write_text("dummy\n", encoding="utf-8")
        fake_vivado.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "from pathlib import Path",
                    "import shutil",
                    "import sys",
                    "source = Path(sys.argv[sys.argv.index('-source') + 1])",
                    f"shutil.copy2(source, Path({str(captured_tcl)!r}))",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        fake_vivado.chmod(0o755)

        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "run_vivado_sim.py"),
                "--project",
                str(project),
                "--vivado",
                str(fake_vivado),
                "--pace-chunks",
                "1",
            ],
            cwd=ROOT,
            check=True,
        )

        self.assertIn(
            "set ::RUN_SIM_PACE_CHUNKS 1",
            captured_tcl.read_text(encoding="utf-8"),
        )

    def test_analyze_cli_joins_window_scores_and_writes_summary(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-analysis-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(f"{sample_index * 1e-9:.12e},0.0" for sample_index in range(257))
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        case_dir = out_dir / "scope"
        (case_dir / "scores.csv").write_text(
            "sample_id,hex_out,float_out,label,prediction,correct,latency_cycles_cnn,latency_us\n"
            "0,0x003ff800,-1.000000,0,0,1,200,1.000\n"
            "1,0x00001000,2.000000,0,1,0,205,1.025\n",
            encoding="utf-8",
        )
        (case_dir / "simulate.log").write_text(
            "Chunk overflows:  0\n"
            "ADC input overflows: 0\n"
            "Dropped triggers: 0\n"
            "Ring misses:      0\n",
            encoding="utf-8",
        )

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        with (case_dir / "scores_annotated.csv").open(
            newline="", encoding="utf-8"
        ) as csv_file:
            annotated = list(csv.DictReader(csv_file))
        with (out_dir / "scan_summary.csv").open(newline="", encoding="utf-8") as csv_file:
            summary = list(csv.DictReader(csv_file))

        self.assertEqual(
            [(row["window_start_ns"], row["float_out"]) for row in annotated],
            [("0.000000", "-1.000000"), ("1.000000", "2.000000")],
        )
        self.assertEqual(summary, [
            {
                "case_name": "scope",
                "source_file": "scope.csv",
                "window_count": "2",
                "score_min": "-1.000000",
                "score_max": "2.000000",
                "score_mean": "0.500000",
                "score_threshold": "0.000000",
                "triggered_windows": "1",
                "trigger_fraction": "0.500000",
            }
        ])
        self.assertTrue((case_dir / "score_vs_window_start.png").exists())
        self.assertTrue((case_dir / "score_histogram.png").exists())
        self.assertTrue((out_dir / "score_vs_window_start_overlay.png").exists())
        self.assertTrue((out_dir / "score_histogram_overlay.png").exists())

    def test_analyze_cli_rejects_nonzero_simulation_health_counter(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-health-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(f"{sample_index * 1e-9:.12e},0.0" for sample_index in range(256))
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        case_dir = out_dir / "scope"
        (case_dir / "scores.csv").write_text(
            "sample_id,float_out\n0,1.000000\n",
            encoding="utf-8",
        )
        (case_dir / "simulate.log").write_text(
            "Chunk overflows:  0\n"
            "ADC input overflows: 0\n"
            "Dropped triggers: 1\n"
            "Ring misses:      0\n",
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
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dropped triggers=1", result.stderr)

    def test_analyze_cli_rejects_incomplete_scores_and_removes_stale_annotation(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-incomplete-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(f"{sample_index * 1e-9:.12e},0.0" for sample_index in range(257))
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        case_dir = out_dir / "scope"
        (case_dir / "scores.csv").write_text(
            "sample_id,float_out\n0,1.000000\n",
            encoding="utf-8",
        )
        (case_dir / "simulate.log").write_text(
            "Chunk overflows:  0\n"
            "ADC input overflows: 0\n"
            "Dropped triggers: 0\n"
            "Ring misses:      0\n",
            encoding="utf-8",
        )
        annotated_path = case_dir / "scores_annotated.csv"
        annotated_path.write_text("stale\n", encoding="utf-8")

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete score CSV", result.stderr)
        self.assertFalse(annotated_path.exists())


if __name__ == "__main__":
    unittest.main()
