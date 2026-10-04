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
    def test_continuous_stream_cannot_succeed_with_missing_scores(self):
        with tempfile.TemporaryDirectory(prefix="ai-trigger-stream-missing-") as work:
            root = Path(work)
            source = root / "source.csv"
            source.write_text("x-axis,1\nsecond,Volt\n" + "\n".join(
                f"{i * 1e-9:.12e},0" for i in range(256)) + "\n")
            case = scope.prepare_scope_csv(source, root / "out", .8, schedule="stream")
            (case / "scores.csv").write_text("sample_id,hex_out,float_out\n0,0x001fff80,-.25\n")
            (case / "events.csv").write_text("event_index,event_chunk_id\n")
            (case / "simulate.log").write_text(
                "Chunk overflows: 0\nADC input overflows: 0\nDropped triggers: 0\n"
                "Ring misses: 0\nHi-Lo blanking: 0\nEvent loss: 0\n")
            with self.assertRaisesRegex(SystemExit, "incomplete continuous scores"):
                stream.analyze_stream(case, mode=2, threshold_raw=45)

    def test_native_reference_receives_gain_after_adc_and_zero_unused_channels(self):
        with tempfile.TemporaryDirectory(prefix="ai-trigger-stream-reference-") as work:
            root = Path(work)
            (root / "weights").mkdir()
            engine = root / "native_reference"
            engine.write_text(f"#!{sys.executable}\n" +
                              "from pathlib import Path\nfrom array import array\n" +
                              "a=array('f');a.frombytes(Path('features.f32').read_bytes())\n" +
                              "assert list(a[:8])==[6.,0.,0.,0.,-6.,0.,0.,0.]\n" +
                              "assert len(a)==1024 and all(v==0 for v in a[8:])\n" +
                              "Path('all_expected.hex').write_text('00000300\\n')\n")
            engine.chmod(0o755)
            reference = stream.NativeReference(engine, root / "scratch")
            self.assertEqual(reference.scores([[64, -64] + [0] * 254]), [768])

    def test_xsim_replay_receives_the_complete_stream_and_gate_configuration(self):
        with tempfile.TemporaryDirectory(prefix="ai-trigger-xsim-replay-") as work:
            root = Path(work)
            source = root / "source.csv"
            source.write_text("x-axis,1\nsecond,Volt\n" + "\n".join(
                f"{i * 1e-9:.12e},0" for i in range(256)) + "\n")
            prepared = scope.prepare_scope_csv(source, root / "inputs", .8,
                                               schedule="stream", pad_before=256)
            fake = root / "xsim"
            fake.write_text(f"#!{sys.executable}\n" +
                            "import sys,json\nfrom pathlib import Path\n" +
                            "p=Path(sys.argv[sys.argv.index('-log')+1])\n" +
                            "p.write_text('Simulation complete.\\n')\n" +
                            "p.with_name('args.json').write_text(json.dumps(sys.argv[1:]))\n")
            fake.chmod(0o755)
            snapshot = root / "snapshot"
            snapshot.mkdir()
            config = {"input_dir": str(prepared), "mode": 4, "threshold_raw": -2147483648,
                      "hl_threshold_raw": 35, "hilo_window": 8}
            stream.run_snapshot(snapshot, root / "run", config, fake)
            args = json.loads((root / "run/args.json").read_text())
            self.assertIn("NUM_SAMPLES=3", args)
            self.assertIn("TRIGGER_MODE=4", args)
            self.assertIn("CNN_THRESH_RAW=-2147483648", args)
            self.assertIn("HL_THRESH=35", args)
            self.assertIn("HILO_WINDOW=8", args)
            self.assertIn("BIN_THR=1", args)

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
