import importlib.util
import tempfile
import unittest
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
