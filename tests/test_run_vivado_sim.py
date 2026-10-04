import importlib.util
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "run_vivado_sim", ROOT / "scripts" / "run_vivado_sim.py"
)
assert SPEC is not None and SPEC.loader is not None
RUN_VIVADO_SIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN_VIVADO_SIM)


class RunVivadoSimLogValidationTest(unittest.TestCase):
    def test_rejects_xsim_fatal_even_when_vivado_returned_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "simulate.log"
            log.write_text(
                "Fatal: Event output bubble\n$finish called at time : 100 ns\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(RuntimeError, "Fatal"):
                RUN_VIVADO_SIM.validate_simulation_log(log)

    def test_accepts_a_completed_simulation_without_testbench_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "simulate.log"
            log.write_text(
                "Simulation complete.\n$finish called at time : 100 ns\n",
                encoding="utf-8",
            )

            RUN_VIVADO_SIM.validate_simulation_log(log)


class RunVivadoSimMultimodeConfigurationTest(unittest.TestCase):
    def test_isolated_simulation_creates_a_native_xpm_project(self) -> None:
        with patch("sys.argv", ["run_vivado_sim.py", "--isolated-output", "/tmp/scan-vendor"]):
            args = RUN_VIVADO_SIM.parse_args()
        project = Path("/tmp/scan-vendor/project/ai_trigger_scan.xpr")
        tcl = RUN_VIVADO_SIM.build_tcl(args, ROOT, project)
        self.assertIn("create_project ai_trigger_scan {/tmp/scan-vendor/project}", tcl)
        self.assertIn("-part xcku5p-ffvb676-2-e", tcl)
        self.assertIn("set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO}", tcl)
        self.assertIn("set_property top tb_AI_TRIGGER_TOP", tcl)
        self.assertIn("set ::RUN_SIM_PROJECT {/tmp/scan-vendor/project/ai_trigger_scan.xpr}", tcl)
        self.assertNotIn("open_project", tcl)

    def test_cli_accepts_full_byte_windows_without_changing_defaults(self) -> None:
        with patch("sys.argv", ["run_vivado_sim.py", "--hilo-window", "255", "--coinc-window", "255"]):
            args = RUN_VIVADO_SIM.parse_args()
        self.assertEqual((args.hilo_window, args.coinc_window), (255, 255))
        tcl = RUN_VIVADO_SIM.build_tcl(args, ROOT, ROOT / "test.xpr")
        self.assertIn("set ::RUN_SIM_HILO_WINDOW 255", tcl)
        self.assertIn("set ::RUN_SIM_COINC_WINDOW 255", tcl)
        with patch("sys.argv", ["run_vivado_sim.py"]):
            defaults = RUN_VIVADO_SIM.parse_args()
        self.assertEqual((defaults.hilo_window, defaults.coinc_window), (5, 3))

    def test_build_tcl_forwards_trigger_mode_hilo_and_force_schedule(self) -> None:
        args = SimpleNamespace(
            testhex_dir=None,
            out_csv=None,
            event_csv=None,
            num_samples=1000,
            score_threshold=0.0,
            cnn_thresh_raw=0,
            mirror_raw_channels=1,
            trigger_mode=4,
            force_trigger_interval=4,
            force_trigger_beat=31,
            hl_thresh=192,
            hilo_window=5,
            coinc_window=32,
            bin_thr=2,
        )

        tcl = RUN_VIVADO_SIM.build_tcl(
            args,
            ROOT,
            ROOT / "AI_Trigger_System" / "AI_Trigger_System.xpr",
        )

        expected_globals = {
            "RUN_SIM_TRIGGER_MODE": 4,
            "RUN_SIM_FORCE_TRIGGER_INTERVAL": 4,
            "RUN_SIM_FORCE_TRIGGER_BEAT": 31,
            "RUN_SIM_HL_THRESH": 192,
            "RUN_SIM_HILO_WINDOW": 5,
            "RUN_SIM_COINC_WINDOW": 32,
            "RUN_SIM_BIN_THR": 2,
        }
        for name, value in expected_globals.items():
            self.assertIn(f"set ::{name} {value}", tcl)


if __name__ == "__main__":
    unittest.main()
