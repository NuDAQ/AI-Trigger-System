"""Normalized model fixtures must keep their scale through fixed x4.4 ingress."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'build_native_reference', ROOT / 'scripts/build_native_reference.py')
REFERENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFERENCE)


class NativeReferenceInputTest(unittest.TestCase):
    def test_normalized_inputs_are_encoded_before_the_fixed_gain(self):
        model = np.array([1., -1., 3., -3., .1875, -.1875, 0.])
        raw = REFERENCE.normalized_to_adc(model)
        # Worked x4.4 ADC encodings: +/-1 -> +/-15, +/-3 -> +/-44.
        np.testing.assert_array_equal(raw, [15, -15, 44, -44, 3, -3, 0])
        np.testing.assert_allclose(
            raw.astype(float) * REFERENCE.CNN_INPUT_GAIN / 64,
            [1.03125, -1.03125, 3.025, -3.025, .20625, -.20625, 0.],
            rtol=0, atol=1e-15)

    @unittest.skipUnless(os.environ.get('AI_NATIVE_REFERENCE'),
                         'Set AI_NATIVE_REFERENCE to a generated amphp reference bundle')
    def test_amphp_zero_score_uses_the_reported_native_unit(self):
        reference = Path(os.environ['AI_NATIVE_REFERENCE'])
        metadata = json.loads((reference / 'reference.json').read_text())
        word = int((reference / 'all_expected.hex').read_text().splitlines()[0], 16)
        code = word - 0x200000 if word & 0x100000 else word
        # Independent new-model Vitis zero-window result: 0x001ff787.
        self.assertEqual(code / metadata['native_score_scale'], -2.1181640625)


if __name__ == '__main__':
    unittest.main()
