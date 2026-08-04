import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "analyze_trigger_mode_sweep",
    ROOT / "scripts" / "analyze_trigger_mode_sweep.py",
)
assert SPEC is not None and SPEC.loader is not None
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)

RUNNER_SPEC = importlib.util.spec_from_file_location(
    "run_trigger_mode_sweep",
    ROOT / "scripts" / "run_trigger_mode_sweep.py",
)
assert RUNNER_SPEC is not None and RUNNER_SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)


class TriggerModeSweepAnalysisTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.labels = [1, 0, 1, 0]

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_scores(self, predictions: list[int]) -> Path:
        path = self.root / "scores.csv"
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=["sample_id", "prediction"])
            writer.writeheader()
            for sample_id, prediction in enumerate(predictions):
                writer.writerow({"sample_id": sample_id, "prediction": prediction})
        return path

    def write_events(self, sample_ids: list[int]) -> Path:
        path = self.root / "events.csv"
        fields = ["event_index", "event_timestamp", "event_batch_index", "event_last"]
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for event_index, sample_id in enumerate(sample_ids):
                for beat in range(64):
                    writer.writerow(
                        {
                            "event_index": event_index,
                            "event_timestamp": sample_id,
                            "event_batch_index": beat,
                            "event_last": int(beat == 63),
                        }
                    )
        return path

    def test_housekeeping_modes_report_contracts_not_classification_accuracy(self) -> None:
        scores = self.write_scores([])

        capture = ANALYZER.analyze_mode(
            0,
            self.labels,
            scores,
            self.write_events([0, 1, 2, 3]),
            force_trigger_interval=2,
        )
        self.assertIsNone(capture["classification"])
        self.assertEqual(capture["contract"]["name"], "capture_every_chunk")
        self.assertTrue(capture["contract"]["exact_match"])

        external = ANALYZER.analyze_mode(
            1,
            self.labels,
            scores,
            self.write_events([0, 2]),
            force_trigger_interval=2,
        )
        self.assertIsNone(external["classification"])
        self.assertEqual(external["contract"]["name"], "scheduled_force_trigger")
        self.assertTrue(external["contract"]["exact_match"])

    def test_trigger_modes_classify_from_final_events(self) -> None:
        scores = self.write_scores([1, 0, 0, 0])
        events = self.write_events([0])

        result = ANALYZER.analyze_mode(
            2,
            self.labels,
            scores,
            events,
            force_trigger_interval=2,
        )

        self.assertEqual(
            result["classification"],
            {
                "tp": 1,
                "tn": 2,
                "fp": 0,
                "fn": 1,
                "accuracy": 0.75,
                "recall": 0.5,
                "false_positive_rate": 0.0,
                "precision": 1.0,
            },
        )
        self.assertTrue(result["contract"]["score_event_exact_match"])

    def test_gated_mode_reports_cnn_admission_cost_without_using_work_ids_as_labels(self) -> None:
        scores = self.write_scores([1, 0])
        events = self.write_events([2])

        result = ANALYZER.analyze_mode(
            4,
            self.labels,
            scores,
            events,
            force_trigger_interval=2,
        )

        self.assertEqual(result["cnn_evaluated"], 2)
        self.assertEqual(result["cnn_accepted"], 1)
        self.assertTrue(result["contract"]["accepted_score_count_matches_events"])
        self.assertEqual(result["classification"]["tp"], 1)


class TriggerModeSweepRunnerTest(unittest.TestCase):
    def test_all_modes_share_identical_stimulus_and_configuration(self) -> None:
        args = SimpleNamespace(
            project=Path("AI_Trigger_System/AI_Trigger_System.xpr"),
            vivado=Path("/tools/Xilinx/Vivado/2023.2/bin/vivado"),
            num_samples=1000,
            score_threshold=0.0,
            cnn_thresh_raw=0,
            force_trigger_interval=4,
            force_trigger_beat=31,
            hl_thresh=192,
            hilo_window=5,
            coinc_window=32,
            bin_thr=2,
        )
        testhex = Path("/tmp/shared-testhex")
        mode_dir = Path("/tmp/mode-0100")

        command = RUNNER.build_mode_command(args, ROOT, testhex, mode_dir, 4)

        expected_pairs = {
            "--testhex-dir": str(testhex),
            "--trigger-mode": "4",
            "--force-trigger-interval": "4",
            "--force-trigger-beat": "31",
            "--hl-thresh": "192",
            "--hilo-window": "5",
            "--coinc-window": "32",
            "--bin-thr": "2",
            "--mirror-raw-channels": "1",
        }
        for option, expected in expected_pairs.items():
            index = command.index(option)
            self.assertEqual(command[index + 1], expected)


if __name__ == "__main__":
    unittest.main()
