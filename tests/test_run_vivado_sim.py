import importlib.util
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
