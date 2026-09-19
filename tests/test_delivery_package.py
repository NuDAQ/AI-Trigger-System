#!/usr/bin/env python3
"""Checks for the DAQ delivery package generator."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class DeliveryPackageTest(unittest.TestCase):
    def test_gitignore_tracks_delivery_config_but_not_generated_dist(self) -> None:
        gitignore = read(".gitignore")

        self.assertIn("!delivery/", gitignore)
        self.assertIn("!delivery/**", gitignore)
        self.assertIn("/dist/", gitignore)

    def test_delivery_docs_define_package_policy(self) -> None:
        doc = read("delivery/README.md")
        manifest = read("delivery/package_manifest.yml")

        self.assertIn("DAQ delivery package", doc)
        self.assertIn("scripts/package_delivery.py", doc)
        self.assertIn("docs/Deliverables.md", manifest)
        self.assertIn("HDL/constraints/ai_trigger_ooc.xdc", manifest)
        self.assertIn("bender", manifest.lower())

    def test_package_generator_builds_self_contained_rtl_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/package_delivery.py"),
                    "--version",
                    "test-delivery",
                    "--out-dir",
                    str(out_dir),
                ],
                cwd=ROOT,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            package = out_dir / "ai-trigger-daq-test-delivery"
            package_zip = out_dir / "ai-trigger-daq-test-delivery.zip"
            add_files = (package / "scripts" / "add_files.tcl").read_text(encoding="utf-8")
            manifest = (package / "MANIFEST.txt").read_text(encoding="utf-8")
            readme = (package / "README.md").read_text(encoding="utf-8")

            self.assertTrue(package_zip.exists())
            self.assertTrue((package / "README.md").exists())
            self.assertTrue((package / "assets" / "score_vs_offset.png").exists())
            version = (package / "VERSION.txt").read_text()
            self.assertIn("cnn-core revision: eca9b12f9f49f4b7324ed9ed241a44086ca9c842", version)
            self.assertIn("hilo-trigger revision: 047d14a25ca0df95d2219eded90e0b449574ae15", version)
            self.assertIn("Hi-Lo windows: unsigned 8-bit accepted-sample counts", version)
            self.assertIn("CNN lanes: 2", version)
            self.assertIn("Score format: signed low 21 bits / 512", version)
            self.assertTrue((package / "constraints" / "ai_trigger_ooc.xdc").exists())
            self.assertTrue((package / "rtl" / "cnn-core" / "cnn_core.v").exists())
            self.assertTrue((package / "rtl" / "cnn-core-wrapper" / "hw" / "rtl" / "cnn_core_wrapper_top.v").exists())
            self.assertTrue((package / "rtl" / "hilo-trigger" / "PRE_TRIGGER_PKG.vhd").exists())
            self.assertTrue((package / "rtl" / "hilo-trigger" / "Pre_trigger.vhd").exists())
            self.assertTrue((package / "rtl" / "ai-trigger" / "AI_TRIGGER_TOP.vhd").exists())

            self.assertNotIn(str(ROOT), add_files)
            self.assertNotIn(str(ROOT), manifest)
            self.assertNotIn(str(ROOT), readme)
            self.assertIn("![score_vs_offset](assets/score_vs_offset.png)", readme)
            self.assertIn("assets/score_vs_offset.png", manifest)
            self.assertIn("rtl/cnn-core/cnn_core.v", manifest)
            self.assertIn("rtl/cnn-core-wrapper/hw/rtl/cnn_core_wrapper_top.v", manifest)
            self.assertIn("rtl/hilo-trigger/PRE_TRIGGER_PKG.vhd", manifest)
            self.assertIn("rtl/hilo-trigger/Pre_trigger.vhd", manifest)
            self.assertIn("rtl/ai-trigger/AI_TRIGGER_PKG.vhd", manifest)

            native_assets = list((package / "rtl/cnn-core").glob("*.vh"))
            native_roms = list((package / "rtl/cnn-core").glob("*.dat"))
            self.assertEqual(len(native_assets), 3)
            self.assertEqual(len(native_roms), 1)
            for asset in native_assets + native_roms:
                self.assertIn(asset.name, add_files)
            self.assertTrue((package / "SHA256SUMS").is_file())
            self.assertNotIn("wrapper_ooc_top", add_files)

            core_idx = add_files.index("rtl cnn-core cnn_core.v")
            wrapper_idx = add_files.index("rtl cnn-core-wrapper hw rtl cnn_core_wrapper_top.v")
            hilo_idx = add_files.index("rtl hilo-trigger PRE_TRIGGER_PKG.vhd")
            pkg_idx = add_files.index("rtl ai-trigger AI_TRIGGER_PKG.vhd")
            top_idx = add_files.index("rtl ai-trigger AI_TRIGGER_TOP.vhd")

            self.assertLess(core_idx, wrapper_idx)
            self.assertLess(wrapper_idx, hilo_idx)
            self.assertLess(hilo_idx, pkg_idx)
            self.assertLess(pkg_idx, top_idx)
            self.assertNotIn("set_property top", add_files)
            self.assertIn("Keep the integrator's existing project top unchanged", add_files)
            self.assertIn("set_property verilog_define", add_files)


if __name__ == "__main__":
    unittest.main()
