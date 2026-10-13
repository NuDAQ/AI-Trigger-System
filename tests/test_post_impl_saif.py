#!/usr/bin/env python3
"""Public contract tests for the post-implementation SAIF launcher."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import hashlib
import json
import os
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
    def test_git_tracks_small_saif_evidence_but_ignores_large_products(self) -> None:
        tracked = [
            "build/vivado_post_impl_saif_30chunks/run_manifest.json",
            "build/vivado_post_impl_saif_30chunks/reports/post_route_power_saif.rpt",
            "build/vivado_post_impl_saif_30chunks/xsim/xsim.log",
            "build/vivado_post_impl_saif_30chunks/generated/run_vivado_post_impl_saif.tcl",
        ]
        ignored = [
            "build/vivado_post_impl_saif_30chunks/activity/ai_trigger_post_impl.saif",
            "build/vivado_post_impl_saif_30chunks/netlist/AI_TRIGGER_TOP_post_route.v",
        ]

        for path in tracked:
            result = subprocess.run(
                ["git", "check-ignore", "-q", path], cwd=ROOT
            )
            self.assertNotEqual(result.returncode, 0, path)
        for path in ignored:
            result = subprocess.run(
                ["git", "check-ignore", "-q", path], cwd=ROOT
            )
            self.assertEqual(result.returncode, 0, path)

    def test_readme_documents_the_current_thirty_chunk_power_flow(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("Post-route SAIF power", readme)
        self.assertIn("python3 scripts/run_post_impl_saif.py", readme)
        self.assertIn("30 acquisition chunks", readme)
        self.assertIn("AI_TRIGGER_TOP", readme)
        self.assertIn("build/vivado_post_impl_saif_30chunks", readme)
        self.assertNotIn(
            "The older `run_post_impl_saif.py` flow is retained as historical tooling",
            readme,
        )

    def test_readme_links_the_qualified_thirty_chunk_result(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("1.972 W", readme)
        self.assertIn(
            "docs/qualification/saif_30chunks_20260926/README.md",
            readme,
        )

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
        self.assertIn("if (i == chunks * BEATS_PER_CHUNK - 1)", testbench)
        self.assertRegex(
            testbench,
            r"data_str\s*=\s*0;\s*repeat\s*\(2\)\s*@\(negedge clk_adc\);\s*"
            r"// Draining suppresses new CNN work",
        )
        self.assertIn("while (active_trigger_mode != 4'hf)", testbench)
        self.assertIn("drain_boundaries", testbench)
        self.assertIn("PASS production SAIF chunks=", testbench)

    def test_vivado_flow_targets_current_production_hierarchy(self) -> None:
        flow = (ROOT / "scripts" / "vivado_post_impl_saif.tcl").read_text(
            encoding="utf-8"
        )

        self.assertIn("AI_TRIGGER_TOP_post_route.v", flow)
        self.assertIn("HDL sim tb_ai_trigger_power.sv", flow)
        self.assertIn("proc saif_log_child_scope", flow)
        self.assertIn("get_scopes", flow)
        self.assertIn("{gen_lanes[0].u_LANE}", flow)
        self.assertIn("{gen_lanes[1].u_LANE}", flow)
        self.assertIn("SAIF child scope", flow)
        self.assertNotIn("gen_lanes[2]", flow)
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
        self.assertEqual(args.saif_start_us, 0.5)
        self.assertFalse(hasattr(args, "saif_scope"))
        self.assertFalse(hasattr(args, "testhex_dir"))
        self.assertFalse(hasattr(args, "score_threshold"))

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

            env = dict(**os.environ, VIVADO_INVOKED=str(invoked))
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

    def test_cli_rejects_a_zero_exit_without_fresh_saif_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            reference = tmp / "reference"
            reference.mkdir()
            npz = tmp / "verification.npz"
            npz.write_bytes(b"same corpus")
            adc = reference / "adc.hex"
            expected = reference / "all_expected.hex"
            adc.write_text("0\n", encoding="utf-8")
            expected.write_text("0\n", encoding="utf-8")
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (reference / "reference.json").write_text(
                json.dumps(
                    {
                        "windows": 1,
                        "builtin_windows": 0,
                        "npz_sha256": digest(npz),
                        "files": {
                            "adc.hex": digest(adc),
                            "all_expected.hex": digest(expected),
                        },
                    }
                ),
                encoding="utf-8",
            )
            dcp = tmp / "post_route.dcp"
            dcp.write_bytes(b"checkpoint")
            vivado = tmp / "vivado"
            vivado.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            vivado.chmod(0o755)

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
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required SAIF artifact", result.stderr)

    def test_cli_writes_a_hashed_manifest_after_a_complete_run(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            reference = tmp / "reference"
            reference.mkdir()
            npz = tmp / "verification.npz"
            npz.write_bytes(b"same corpus")
            adc = reference / "adc.hex"
            expected = reference / "all_expected.hex"
            adc.write_text("0\n", encoding="utf-8")
            expected.write_text("0\n", encoding="utf-8")
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            (reference / "reference.json").write_text(
                json.dumps(
                    {
                        "windows": 1,
                        "builtin_windows": 0,
                        "npz_sha256": digest(npz),
                        "files": {
                            "adc.hex": digest(adc),
                            "all_expected.hex": digest(expected),
                        },
                    }
                ),
                encoding="utf-8",
            )
            dcp = tmp / "post_route.dcp"
            dcp.write_bytes(b"checkpoint")
            vivado = tmp / "vivado"
            vivado.write_text(
                """#!/usr/bin/env python3
from pathlib import Path
import re
import sys

launcher = Path(sys.argv[sys.argv.index("-source") + 1]).read_text()
out = Path(re.search(r"RUN_SAIF_OUT_DIR \\{([^}]*)\\}", launcher).group(1))
files = {
    "activity/ai_trigger_post_impl.saif": "(SAIFILE)\\n",
    "xsim/xsim.log": "PASS production SAIF chunks=1 events=0 start_window=0\\n",
    "reports/post_route_power_saif.rpt": "Total On-Chip Power (W) | 1.0\\nConfidence Level | High\\n",
    "reports/post_route_utilization_for_saif.rpt": "utilization\\n",
    "reports/post_route_timing_summary_for_saif.rpt": "timing\\n",
}
for name, content in files.items():
    path = out / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
""",
                encoding="utf-8",
            )
            vivado.chmod(0o755)
            out = tmp / "out"

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
                    str(out),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["top"], "AI_TRIGGER_TOP")
            self.assertEqual(manifest["activity"]["chunks"], 1)
            self.assertEqual(manifest["activity"]["start_window"], 0)
            self.assertEqual(manifest["inputs"]["npz_sha256"], digest(npz))
            self.assertEqual(manifest["inputs"]["dcp_sha256"], digest(dcp))
            self.assertEqual(
                manifest["outputs"]["reports/post_route_power_saif.rpt"],
                digest(out / "reports" / "post_route_power_saif.rpt"),
            )


if __name__ == "__main__":
    unittest.main()
