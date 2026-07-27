#!/usr/bin/env python3
"""Behavior tests for the NSF Jul 27 continuous-trigger simulation flow."""

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_nsf_jul_27_sim.py"


class NsfJul27SimulationTest(unittest.TestCase):
    @staticmethod
    def write_score_csv(path: Path) -> None:
        path.write_text(
            "\n".join(
                [
                    "sample_id,hex_out,float_out,label,prediction,correct,"
                    "latency_cycles_cnn,latency_us,input_first_fire_time_ns,"
                    "input_last_fire_time_ns,cnn_result_time_ns",
                    "0,0x00001800,3.000000,1,1,1,204,1.020,100,352,1120",
                    "1,0x003ff000,-2.000000,0,0,1,203,1.015,356,608,1380",
                    "",
                ]
            ),
            encoding="utf-8",
        )

    @staticmethod
    def write_event_csv(path: Path) -> None:
        first_batch = (
            "000000000000000000000000000000000000000000000000"
            "000000000f80000000000140000000000040000000000fe0"
        )
        zero_batch = "0" * 96
        lines = [
            "event_index,event_chunk_id,event_timestamp,event_score_hex,"
            "event_batch_index,event_last,event_data_hex,event_output_time_ns,"
            "event_valid,event_ready,event_fire"
        ]
        for batch_index in range(64):
            event_data = first_batch if batch_index == 0 else zero_batch
            lines.append(
                f"0,0,0,0x00001800,{batch_index},{int(batch_index == 63)},"
                f"0x{event_data},{2000 + batch_index * 12},1,1,1"
            )
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    @staticmethod
    def write_clean_log(path: Path) -> None:
        path.write_text(
            "\n".join(
                [
                    "Chunk overflows:  0 (should be 0 in normal operation)",
                    "ADC input overflows: 0",
                    "Dropped triggers: 0",
                    "Ring misses:      0",
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def test_prepare_cli_generates_quantized_testhex_and_source_chunk_mapping(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-jul-27-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"

        waveforms = np.zeros((2, 4, 256, 1), dtype=np.float32)
        waveforms[0, :, 0, 0] = [-0.5, 1.0, 5.0, -2.0]
        labels = np.array([1.0, 0.0], dtype=np.float32)
        np.save(x_path, waveforms)
        np.save(y_path, labels)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--source-chunk-base",
                "490",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        testhex_dir = out_dir / "testhex_stream"
        sample0 = (
            testhex_dir / "test_input_sample0.hex"
        ).read_text(encoding="utf-8").splitlines()
        written_labels = (
            testhex_dir / "labels.hex"
        ).read_text(encoding="utf-8").splitlines()
        with (out_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest = list(csv.DictReader(csv_file))

        self.assertEqual(len(sample0), 256)
        self.assertEqual(sample0[0], "0000f80140040fe0")
        self.assertEqual(set(sample0[1:]), {"0000000000000000"})
        self.assertEqual(written_labels, ["1", "0"])
        self.assertEqual(
            manifest,
            [
                {"local_chunk_id": "0", "source_chunk_id": "490", "label": "1"},
                {"local_chunk_id": "1", "source_chunk_id": "491", "label": "0"},
            ],
        )

    def test_analyze_cli_writes_complete_signal_and_ignored_noise_to_one_csv(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-report-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"
        report_path = out_dir / "NSF_Jul_27_trigger_trace.csv"
        scores_path = out_dir / "scores.csv"
        events_path = out_dir / "events.csv"
        log_path = out_dir / "simulate.log"

        waveforms = np.zeros((2, 4, 256, 1), dtype=np.float32)
        waveforms[0, :, 0, 0] = [-0.5, 1.0, 5.0, -2.0]
        labels = np.array([1.0, 0.0], dtype=np.float32)
        np.save(x_path, waveforms)
        np.save(y_path, labels)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--source-chunk-base",
                "490",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        self.write_score_csv(scores_path)
        self.write_event_csv(events_path)
        self.write_clean_log(log_path)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
                "--scores-csv",
                str(scores_path),
                "--events-csv",
                str(events_path),
                "--log",
                str(log_path),
                "--report-csv",
                str(report_path),
                "--cnn-thresh-raw",
                "0",
                "--mirror-raw-channels",
                "0",
            ],
            cwd=ROOT,
            check=True,
        )

        with report_path.open(newline="", encoding="utf-8") as csv_file:
            rows = list(csv.DictReader(csv_file))

        self.assertEqual(len(rows), 128)
        first_signal = rows[0]
        last_signal = rows[63]
        first_noise = rows[64]

        self.assertEqual(first_signal["source_chunk_id"], "490")
        self.assertEqual(first_signal["local_chunk_id"], "0")
        self.assertEqual(first_signal["label"], "1")
        self.assertEqual(first_signal["input_batch_index"], "0")
        self.assertEqual(first_signal["input_first_fire_time_ns"], "100")
        self.assertEqual(first_signal["input_last_fire_time_ns"], "352")
        self.assertEqual(first_signal["input_stream_complete"], "1")
        self.assertEqual(first_signal["input_ch0_s0"], "-32")
        self.assertEqual(first_signal["input_ch1_s0"], "64")
        self.assertEqual(first_signal["input_ch2_s0"], "320")
        self.assertEqual(first_signal["input_ch3_s0"], "-128")
        self.assertEqual(first_signal["input_ch4_s0"], "0")
        self.assertEqual(first_signal["trigger_decision"], "1")
        self.assertEqual(first_signal["event_present"], "1")
        self.assertEqual(first_signal["event_timestamp"], "0")
        self.assertEqual(first_signal["event_fire"], "1")
        self.assertEqual(first_signal["waveform_match"], "1")
        self.assertEqual(first_signal["event_complete"], "1")
        self.assertEqual(first_signal["signal_readout_ok"], "1")
        self.assertEqual(last_signal["event_last"], "1")

        self.assertEqual(first_noise["source_chunk_id"], "491")
        self.assertEqual(first_noise["label"], "0")
        self.assertEqual(first_noise["input_fire"], "1")
        self.assertEqual(first_noise["trigger_decision"], "0")
        self.assertEqual(first_noise["event_present"], "0")
        self.assertEqual(first_noise["event_fire"], "0")
        self.assertEqual(first_noise["noise_ignored_ok"], "1")

    def test_analyze_cli_marks_two_adjacent_complete_events_as_continuous(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-continuous-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"
        report_path = out_dir / "NSF_Jul_27_trigger_trace.csv"
        scores_path = out_dir / "scores.csv"
        events_path = out_dir / "events.csv"
        log_path = out_dir / "simulate.log"

        labels = np.array([1, 0, 0, 0, 0, 1, 1], dtype=np.float32)
        np.save(x_path, np.zeros((7, 4, 256, 1), dtype=np.float32))
        np.save(y_path, labels)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--source-chunk-base",
                "490",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        score_lines = [
            "sample_id,hex_out,float_out,label,prediction,correct,"
            "latency_cycles_cnn,latency_us,input_first_fire_time_ns,"
            "input_last_fire_time_ns,cnn_result_time_ns"
        ]
        for chunk_id, label in enumerate(labels.astype(int)):
            triggered = chunk_id in (0, 5, 6)
            score_lines.append(
                f"{chunk_id},{'0x00000800' if triggered else '0x003ff800'},"
                f"{'1.000000' if triggered else '-1.000000'},{label},"
                f"{int(triggered)},1,204,1.020,"
                f"{100 + chunk_id * 256},{352 + chunk_id * 256},"
                f"{1200 + chunk_id * 256}"
            )
        scores_path.write_text("\n".join(score_lines) + "\n", encoding="utf-8")

        event_lines = [
            "event_index,event_chunk_id,event_timestamp,event_score_hex,"
            "event_batch_index,event_last,event_data_hex,event_output_time_ns,"
            "event_valid,event_ready,event_fire"
        ]
        for event_index, chunk_id in enumerate((0, 5, 6)):
            event_start_ns = 2000 + event_index * 1000
            for batch_index in range(64):
                event_lines.append(
                    f"{event_index},{chunk_id},{chunk_id},0x00000800,"
                    f"{batch_index},{int(batch_index == 63)},0x{'0' * 96},"
                    f"{event_start_ns + batch_index * 12},1,1,1"
                )
        events_path.write_text("\n".join(event_lines) + "\n", encoding="utf-8")
        self.write_clean_log(log_path)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
                "--scores-csv",
                str(scores_path),
                "--events-csv",
                str(events_path),
                "--log",
                str(log_path),
                "--report-csv",
                str(report_path),
            ],
            cwd=ROOT,
            check=True,
        )

        with report_path.open(newline="", encoding="utf-8") as csv_file:
            rows = list(csv.DictReader(csv_file))
        first_row_by_chunk = {
            int(row["local_chunk_id"]): row
            for row in rows
            if row["input_batch_index"] == "0"
        }

        self.assertEqual(len(rows), 448)
        self.assertEqual(first_row_by_chunk[0]["continuous_readout_ok"], "0")
        self.assertEqual(first_row_by_chunk[5]["source_chunk_id"], "495")
        self.assertEqual(first_row_by_chunk[5]["event_index"], "1")
        self.assertEqual(first_row_by_chunk[5]["event_timestamp"], "5")
        self.assertEqual(first_row_by_chunk[5]["continuous_readout_ok"], "1")
        self.assertEqual(first_row_by_chunk[6]["source_chunk_id"], "496")
        self.assertEqual(first_row_by_chunk[6]["event_index"], "2")
        self.assertEqual(first_row_by_chunk[6]["event_timestamp"], "6")
        self.assertEqual(first_row_by_chunk[6]["continuous_readout_ok"], "1")

    def test_testbench_csv_contract_records_transaction_times_and_handshakes(self) -> None:
        testbench = (
            ROOT / "HDL" / "sim" / "tb_ai_trigger_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("input_first_fire_time_ns", testbench)
        self.assertIn("input_last_fire_time_ns", testbench)
        self.assertIn("cnn_result_time_ns", testbench)
        self.assertIn("event_output_time_ns", testbench)
        self.assertIn("event_valid,event_ready,event_fire", testbench)
        self.assertIn(".EVENT_READY    (event_ready)", testbench)
        self.assertIn("if (event_valid && event_ready)", testbench)
        self.assertNotIn('{"sample_id,hex_out', testbench)
        self.assertNotIn('{"event_index,event_chunk_id', testbench)

    def test_analyze_cli_fails_when_a_signal_event_is_missing_but_keeps_report(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-missing-event-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"
        report_path = out_dir / "NSF_Jul_27_trigger_trace.csv"
        scores_path = out_dir / "scores.csv"
        events_path = out_dir / "events.csv"
        log_path = out_dir / "simulate.log"

        np.save(x_path, np.zeros((2, 4, 256, 1), dtype=np.float32))
        np.save(y_path, np.array([1, 0], dtype=np.float32))
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        self.write_score_csv(scores_path)
        events_path.write_text(
            "event_index,event_chunk_id,event_timestamp,event_score_hex,"
            "event_batch_index,event_last,event_data_hex,event_output_time_ns,"
            "event_valid,event_ready,event_fire\n",
            encoding="utf-8",
        )
        self.write_clean_log(log_path)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
                "--scores-csv",
                str(scores_path),
                "--events-csv",
                str(events_path),
                "--log",
                str(log_path),
                "--report-csv",
                str(report_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(report_path.exists())
        with report_path.open(newline="", encoding="utf-8") as csv_file:
            first_row = next(csv.DictReader(csv_file))
        self.assertEqual(first_row["label"], "1")
        self.assertEqual(first_row["trigger_decision"], "1")
        self.assertEqual(first_row["event_present"], "0")
        self.assertEqual(first_row["signal_readout_ok"], "0")

    def test_full_cli_runs_vivado_boundary_and_builds_final_report(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-full-cli-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"
        report_path = out_dir / "NSF_Jul_27_trigger_trace.csv"
        scores_fixture = work_dir / "scores_fixture.csv"
        events_fixture = work_dir / "events_fixture.csv"
        xsim_log = work_dir / "simulate.log"
        fake_runner = work_dir / "fake_vivado_runner.py"
        captured_args = work_dir / "captured_args.txt"

        waveforms = np.zeros((2, 4, 256, 1), dtype=np.float32)
        waveforms[0, :, 0, 0] = [-0.5, 1.0, 5.0, -2.0]
        np.save(x_path, waveforms)
        np.save(y_path, np.array([1, 0], dtype=np.float32))
        self.write_score_csv(scores_fixture)
        self.write_event_csv(events_fixture)
        self.write_clean_log(xsim_log)

        fake_runner.write_text(
            "\n".join(
                [
                    "from pathlib import Path",
                    "import shutil",
                    "import sys",
                    "",
                    "def arg_value(name):",
                    "    index = sys.argv.index(name)",
                    "    return sys.argv[index + 1]",
                    "",
                    f"shutil.copy2({str(scores_fixture)!r}, arg_value('--out-csv'))",
                    f"shutil.copy2({str(events_fixture)!r}, arg_value('--event-csv'))",
                    f"Path({str(captured_args)!r}).write_text('\\n'.join(sys.argv[1:]) + '\\n')",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--source-chunk-base",
                "490",
                "--out-dir",
                str(out_dir),
                "--report-csv",
                str(report_path),
                "--sim-runner",
                str(fake_runner),
                "--xsim-log",
                str(xsim_log),
            ],
            cwd=ROOT,
            check=True,
        )

        runner_args = captured_args.read_text(encoding="utf-8").splitlines()
        self.assertEqual(runner_args[runner_args.index("--num-samples") + 1], "2")
        self.assertEqual(
            runner_args[runner_args.index("--testhex-dir") + 1],
            str((out_dir / "testhex_stream").resolve()),
        )
        self.assertEqual(
            runner_args[runner_args.index("--mirror-raw-channels") + 1],
            "0",
        )
        self.assertEqual(
            runner_args[runner_args.index("--score-threshold") + 1],
            "0.0",
        )
        self.assertEqual(
            runner_args[runner_args.index("--cnn-thresh-raw") + 1],
            "0",
        )
        self.assertTrue(report_path.exists())
        self.assertTrue((out_dir / "simulate.log").exists())

    def test_analyze_cli_rejects_event_beat_without_valid_ready_handshake(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-nsf-bad-handshake-"))
        x_path = work_dir / "x.npy"
        y_path = work_dir / "y.npy"
        out_dir = work_dir / "out"
        scores_path = out_dir / "scores.csv"
        events_path = out_dir / "events.csv"
        log_path = out_dir / "simulate.log"

        waveforms = np.zeros((2, 4, 256, 1), dtype=np.float32)
        waveforms[0, :, 0, 0] = [-0.5, 1.0, 5.0, -2.0]
        np.save(x_path, waveforms)
        np.save(y_path, np.array([1, 0], dtype=np.float32))
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--x-data",
                str(x_path),
                "--labels",
                str(y_path),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )
        self.write_score_csv(scores_path)
        self.write_event_csv(events_path)
        event_lines = events_path.read_text(encoding="utf-8").splitlines()
        event_lines[1] = event_lines[1].rsplit(",", 3)[0] + ",0,1,1"
        events_path.write_text("\n".join(event_lines) + "\n", encoding="utf-8")
        self.write_clean_log(log_path)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--analyze-only",
                "--out-dir",
                str(out_dir),
                "--scores-csv",
                str(scores_path),
                "--events-csv",
                str(events_path),
                "--log",
                str(log_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        with (out_dir / "NSF_Jul_27_trigger_trace.csv").open(
            newline="", encoding="utf-8"
        ) as csv_file:
            first_row = next(csv.DictReader(csv_file))
        self.assertEqual(first_row["event_valid"], "0")
        self.assertEqual(first_row["event_complete"], "0")
        self.assertEqual(first_row["signal_readout_ok"], "0")


if __name__ == "__main__":
    unittest.main()
