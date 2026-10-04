"""Full-stream scan results must retain centered raw waveform identity."""
import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts import run_real_noise_scan as scope
from scripts import run_template_stream_scan as stream


class TemplateStreamScanTest(unittest.TestCase):
    def test_cli_prepares_one_complete_stream_for_all_three_modes(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="ai-trigger-stream-cli-") as work:
            out = Path(work) / "out"
            result = subprocess.run([sys.executable, str(root / "scripts/run_template_stream_scan.py"),
                                     "--prepare-only", "--case", "nu_3m_2sigma_ev1",
                                     "--variants", "noisy", "--out-dir", str(out)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plan = json.loads((out / "run_plan.json").read_text())
            self.assertEqual([c["mode"] for c in plan["cases"]], [2, 3, 4, 4])
            self.assertEqual([c["threshold_raw"] for c in plan["cases"]], [45, 45, -2147483648, 45])
            self.assertEqual(len(list((out / "inputs").rglob("test_input_sample*.hex"))), 6)

    def test_centered_event_is_mapped_and_checked_against_original_adc(self):
        with tempfile.TemporaryDirectory(prefix="ai-trigger-centered-") as work:
            root = Path(work)
            values = [0.] * 257
            values[253] = .025
            source = root / "source.csv"
            source.write_text("x-axis,1\nsecond,Volt\n" + "\n".join(
                f"{i * 1e-9:.12e},{v:.12e}" for i, v in enumerate(values)) + "\n")
            case = scope.prepare_scope_csv(source, root / "out", .8,
                                            schedule="stream", pad_before=3)
            (case / "scores.csv").write_text("sample_id,hex_out,float_out\n")
            (case / "simulate.log").write_text(
                "Chunk overflows: 0\nADC input overflows: 0\nDropped triggers: 0\n"
                "Ring misses: 0\nHi-Lo blanking: 0\nEvent loss: 0\n")
            events = case / "events.csv"
            fields = ["event_index", "event_chunk_id", "event_timestamp", "event_trigger_offset",
                      "event_score_hex", "event_batch_index", "event_last", "event_data_hex"]
            def write_event(first_word):
                with events.open("w", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=fields)
                    w.writeheader()
                    for i in range(64):
                        w.writerow(dict(zip(fields, [0, 1, 1, 31, "0x00000000", i,
                                                     int(i == 63), hex(first_word if i == 0 else 0)])))
            write_event(128)
            result = stream.analyze_stream(case, mode=3, threshold_raw=45)
            self.assertEqual(result["raw_events_checked"], 1)
            self.assertEqual(result["events"][0]["source_start_index"], 253)
            write_event(129)
            with self.assertRaisesRegex(SystemExit, "raw waveform mismatch"):
                stream.analyze_stream(case, mode=3, threshold_raw=45)


if __name__ == "__main__":
    unittest.main()
