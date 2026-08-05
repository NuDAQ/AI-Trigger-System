import importlib.util
import unittest
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "plot_hilo_gated_waveforms",
    ROOT / "scripts" / "plot_hilo_gated_waveforms.py",
)
assert SPEC is not None and SPEC.loader is not None
PLOTTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLOTTER)


class HiloGatedWaveformPlotTest(unittest.TestCase):
    def test_cnn_quantization_matches_adc_to_axis16(self) -> None:
        samples = np.array([-13.0, -8.0, -0.04, 0.04, 7.99, 12.0])

        quantized = PLOTTER.quantize_cnn_input(samples)

        np.testing.assert_array_equal(
            quantized,
            np.array([-8.0, -8.0, -0.0625, 0.03125, 7.96875, 7.96875]),
        )

    def test_reconstructs_the_same_31_plus_33_beat_centered_window(self) -> None:
        stream = np.arange(3 * 4 * 256, dtype=float).reshape(3, 4, 256)
        metadata = [{"timestamp": 1, "trigger_offset": 2}]

        windows, addresses = PLOTTER.reconstruct_centered_windows(stream, metadata)

        continuous_ch0 = stream[:, 0, :].reshape(-1)
        expected_start_sample = ((1 * 64 + 2) - 31) * 4
        np.testing.assert_array_equal(
            windows[0, 0],
            continuous_ch0[expected_start_sample : expected_start_sample + 256],
        )
        self.assertEqual(
            addresses[0],
            {"start_chunk": 0, "start_offset": 35, "trigger_sample": 128},
        )


if __name__ == "__main__":
    unittest.main()
