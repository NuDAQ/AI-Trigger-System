"""The public native simulation CLI must reject incomplete vendor runs."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeSimulationCliTest(unittest.TestCase):
    def test_threshold_preserves_the_complete_signed_external_word(self):
        for threshold, encoded in [(-33, 'ffffffdf'), (-2147483648, '80000000'),
                                   (2147483647, '7fffffff')]:
            with self.subTest(threshold=threshold), tempfile.TemporaryDirectory() as folder:
                tmp = Path(folder)
                reference = tmp/'reference'
                reference.mkdir()
                (reference/'reference.json').write_text(json.dumps({'windows':16,'files':{}}))
                vendor = tmp/'vivado'
                vendor.write_text('#!/usr/bin/env python3\n'
                                  'from pathlib import Path\nimport sys\n'
                                  'out=Path(sys.argv[sys.argv.index("-log")+1]).parent\n'
                                  'log=out/"project/sim/simulate.log"\n'
                                  'log.parent.mkdir(parents=True)\n'
                                  f'expected="THRESHOLD={encoded}"\n'
                                  'log.write_text("PASS native system windows=16" if expected in '
                                  '(out/"run.tcl").read_text() else "Fatal: corrupted threshold")\n')
                vendor.chmod(0o755)
                result = subprocess.run([sys.executable,str(ROOT/'scripts/run_native_sim.py'),
                                         '--reference',str(reference),'--output',str(tmp/'result'),
                                         '--threshold',str(threshold),'--vivado',str(vendor)],
                                        cwd=ROOT,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)

    def test_partial_mode_passes_are_not_a_completed_regression(self):
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            reference = tmp/'reference'
            reference.mkdir()
            (reference/'reference.json').write_text(json.dumps({'windows':16,'files':{}}))
            vendor = tmp/'vivado'
            vendor.write_text('#!/usr/bin/env python3\n'
                              'from pathlib import Path\nimport sys\n'
                              'out=Path(sys.argv[sys.argv.index("-log")+1]).parent\n'
                              'log=out/"project/sim/simulate.log"\n'
                              'log.parent.mkdir(parents=True)\n'
                              'log.write_text("PASS native mode=0 events=2 CNN=0\\nSimulator terminated early\\n")\n')
            vendor.chmod(0o755)
            result = subprocess.run([sys.executable,str(ROOT/'scripts/run_native_sim.py'),
                                     '--reference',str(reference),'--output',str(tmp/'result'),
                                     '--testbench','tb_native_modes','--vivado',str(vendor)],
                                    cwd=ROOT,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,'partial success must not qualify all trigger modes')
            self.assertIn('FAIL native simulation',result.stderr)


if __name__ == '__main__':
    unittest.main()
