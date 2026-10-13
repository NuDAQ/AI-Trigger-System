"""Normalized model fixtures must keep their scale through fixed x6 ingress."""
import importlib.util
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
        # Model +/-1 maps to +/-11 ADC codes; +/-3 maps exactly to +/-32.
        np.testing.assert_array_equal(raw, [11, -11, 32, -32, 2, -2, 0])
        np.testing.assert_array_equal(
            raw.astype(float) * 6 / 64,
            [1.03125, -1.03125, 3., -3., .1875, -.1875, 0.])


if __name__ == '__main__':
    unittest.main()
