#!/usr/bin/env python3
"""Public contract tests for the post-implementation SAIF launcher."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from unittest.mock import patch
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location(
    "run_post_impl_saif", ROOT / "scripts" / "run_post_impl_saif.py"
)
assert SPEC and SPEC.loader
RUN_SAIF = module_from_spec(SPEC)
SPEC.loader.exec_module(RUN_SAIF)


class PostImplementationSaifCliTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
