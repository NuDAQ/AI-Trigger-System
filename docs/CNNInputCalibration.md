# Editing CNN input calibration

Only the CNN branch of channels 0..3 is calibrated. Saved event waveforms,
ring storage, all eight raw ADC channels and Hi-Lo detection stay raw.
Continuous AI and gated AI use the same zero-cycle conversion interface.

Edit these two files, then rebuild and qualify the bitstream:

- `HDL/rtl/CNN_INPUT_GAIN_PKG.vhd`: `CNN_INPUT_GAIN_PPM`, indexed explicitly
  by channel. `4_421_578` means gain 4.421578; `1_000_000` means unity.
- `HDL/rtl/CNN_INPUT_OFFSET_PKG.vhd`: `CNN_INPUT_OFFSET_UV`, in microvolts
  at the raw ADC input, before gain. These are baselines to **subtract**;
  `-468` adds 0.468 mV to channel 0. `0` disables baseline correction.

The default ADC range is 800,000 uV peak-to-peak over 4096 signed codes.
Fractional baseline codes are retained. For each channel:

```
baseline_codes = offset_uV * 4096 / ADC_full_scale_uV_pp
model_input = (raw_ADC_code - baseline_codes) * gain / 64
native_code = clamp(floor(model_input * 32 + 0.5), -511, +511)
```

For complete removal of calibration, set all gains to `1_000_000` and all
offsets to `0`. To reproduce the former common 4.4 gain, use `4_400_000` and
zero offsets. The lookup automatically expands its address range if needed.
There is no manually maintained ROM file or saturation threshold to edit.

`CNN_INPUT_CALIBRATION_PKG.cnn_calibrate_adc(raw, channel)` hides the current
constant lookup. `AI_TRIGGER_PKG.adc_to_axis16` is the thin native-slot adapter;
both input packers pass the channel explicitly. The gain and offset functions
run only during constant elaboration, so they add no arithmetic pipeline to
the ADC stream. A future clocked/runtime implementation must preserve stream
valid, lane selection and window metadata alignment and will need an explicit
latency contract at this seam.

`scripts/build_native_reference.py` reads the VHDL configuration directly,
inverse-encodes normalized fixtures, and generates an independent HLS C++
quantization reference for all 4 x 4096 input codes. Regenerate references after
every parameter change. Actual physical ADC recordings retain their raw codes.

Run local GHDL and native reference/Verilator checks, then Vivado system
simulation, routed OOC and full-board timing before using a new bitstream.
Changing four constants does not preserve the prior routed timing result.
