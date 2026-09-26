#!/usr/bin/env python3
"""Public contract tests for the post-implementation SAIF launcher."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import json
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location(
    "run_post_impl_saif", ROOT / "scripts" / "run_post_impl_saif.py"
)
assert SPEC and SPEC.loader
RUN_SAIF = module_from_spec(SPEC)
SPEC.loader.exec_module(RUN_SAIF)


class PostImplementationSaifCliTest(unittest.TestCase):
    def test_gate_testbench_uses_only_the_production_top_contract(self) -> None:
        testbench = (ROOT / "HDL" / "sim" / "tb_ai_trigger_power.sv").read_text(
            encoding="utf-8"
        )

        self.assertIn("AI_TRIGGER_TOP dut", testbench)
        self.assertNotIn("AI_TRIGGER_TOP_TB_WRAP", testbench)
        for plusarg in ("REFERENCE", "CHUNKS", "START_WINDOW", "THRESHOLD"):
            self.assertIn(f'$value$plusargs("{plusarg}=', testbench)
        self.assertIn('/adc.hex"}', testbench)
        self.assertIn('/all_expected.hex"}', testbench)
        self.assertIn("EVENT_LOSS", testbench)
        self.assertIn("PASS production SAIF chunks=", testbench)

    def test_vivado_flow_targets_current_production_hierarchy(self) -> None:
        flow = (ROOT / "scripts" / "vivado_post_impl_saif.tcl").read_text(
            encoding="utf-8"
        )

        self.assertIn("AI_TRIGGER_TOP_post_route.v", flow)
        self.assertIn("HDL sim tb_ai_trigger_power.sv", flow)
        self.assertIn("/tb_ai_trigger_power/dut/u_CORE/gen_lanes\\[0\\].u_LANE", flow)
        self.assertIn("/tb_ai_trigger_power/dut/u_CORE/gen_lanes\\[1\\].u_LANE", flow)
        self.assertNotIn("gen_lanes\\[2\\]", flow)
        self.assertNotIn("AI_TRIGGER_TOP_TB_WRAP", flow)
        self.assertIn("read_saif -strip_path tb_ai_trigger_power/dut", flow)
        for plusarg in ("REFERENCE", "CHUNKS", "START_WINDOW", "THRESHOLD"):
            self.assertIn(f'-testplusarg "{plusarg}=', flow)

    def test_defaults_build_production_top_for_thirty_chunks(self) -> None:
        with patch.object(sys, "argv", ["run_post_impl_saif.py"]):
            args = RUN_SAIF.parse_args()

        self.assertEqual(args.chunks, 30)
        self.assertEqual(args.build_dir, "build/vivado_ooc_ai_trigger")
        self.assertEqual(args.out_dir, "build/vivado_post_impl_saif_30chunks")

        launcher = RUN_SAIF.build_ooc_launcher(
            args,
            ROOT,
            ROOT / args.build_dir,
        )
        self.assertIn("set ::RUN_BUILD_TOP AI_TRIGGER_TOP", launcher)
        self.assertNotIn("AI_TRIGGER_TOP_TB_WRAP", launcher)

    def test_saif_launcher_selects_thirty_npz_chunks_from_reference(self) -> None:
        args = SimpleNamespace(
            chunks=30,
            start_window=96,
            cnn_thresh_raw=0,
            sdf="none",
            saif_start_us=0.5,
            saif_min_objects=1000,
            threads=8,
        )
        reference = ROOT / "build" / "native_validation" / "reference"
        launcher = RUN_SAIF.build_saif_launcher(
            args,
            ROOT,
            ROOT / "build" / "vivado_ooc_ai_trigger" / "checkpoints" / "post_route.dcp",
            ROOT / "build" / "vivado_post_impl_saif_30chunks",
            reference,
        )

        self.assertIn(f"set ::RUN_SAIF_REFERENCE {{{reference}}}", launcher)
        self.assertIn("set ::RUN_SAIF_CHUNKS 30", launcher)
        self.assertIn("set ::RUN_SAIF_START_WINDOW 96", launcher)
        self.assertNotIn("RUN_SAIF_TESTHEX_DIR", launcher)
        self.assertNotIn("RUN_SAIF_NUM_SAMPLES", launcher)

    def test_cli_rejects_reference_built_from_a_different_npz(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            reference = tmp / "reference"
            reference.mkdir()
            (reference / "reference.json").write_text(
                json.dumps(
                    {
                        "windows": 30,
                        "builtin_windows": 0,
                        "npz_sha256": "0" * 64,
                        "files": {},
                    }
                ),
                encoding="utf-8",
            )
            npz = tmp / "verification.npz"
            npz.write_bytes(b"not the recorded NPZ")
            dcp = tmp / "post_route.dcp"
            dcp.write_bytes(b"checkpoint")
            invoked = tmp / "vivado_was_invoked"
            vivado = tmp / "vivado"
            vivado.write_text(
                "#!/bin/sh\ntouch \"$VIVADO_INVOKED\"\nexit 0\n",
                encoding="utf-8",
            )
            vivado.chmod(0o755)

            env = dict(**__import__("os").environ, VIVADO_INVOKED=str(invoked))
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "run_post_impl_saif.py"),
                    "--skip-build",
                    "--dcp",
                    str(dcp),
                    "--reference",
                    str(reference),
                    "--npz",
                    str(npz),
                    "--chunks",
                    "1",
                    "--start-window",
                    "0",
                    "--vivado",
                    str(vivado),
                    "--out-dir",
                    str(tmp / "out"),
                ],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("reference npz_sha256 does not match --npz", result.stderr)
            self.assertFalse(invoked.exists())


if __name__ == "__main__":
    unittest.main()
