# Fixed CNN-only input gain 4.4

Branch: `oct_13_only_upgrade_cnn`. The fixed gain is exactly 22/5 at CNN
ingress. Native input code is round(11*raw/5), symmetrically clipped to
[-511, 511], then sign-extended into the existing 16-bit slots. Fifths never
land on a half-code. A widened absolute value preserves raw=-2048; codes
with magnitude at least 233 clip before the narrow constant arithmetic.

Production changes are confined to AI_TRIGGER_PKG.vhd. Hi-Lo inputs, ring
storage, raw event samples, CNN weights, stream packing, score /1024 and
external threshold /16 retain their existing contracts.

The agreed validation boundaries are ADC conversion into the native stream,
real native CNN input/output versus independent HLS C++, and ADC input to
system score/events. Existing waveform and mode/backend regressions preserve
the raw-data branch.

TDD conversion red fails on the old x6 implementation at raw=-232. Fixed
worked examples cover positive/negative rounding, raw=-2048, and the 232/233
saturation boundary. Targeted conversion/Hi-Lo/gated tests pass. The complete
local GHDL suite passes 39/39. `conversion_logs.tar.gz` preserves the logs.

The conversion also matches independent HLS native quantization for all
4096 signed ADC codes. The regenerated reference preserves normalized fixture
amplitude through ADC encoding round(X*64/4.4), and separately applies exact
4.4 gain to raw gated waveforms. The amphp NPZ hash remains unchanged.

Local checks pass: four native Python tests; 1096 real-CNN Verilator windows
and one gated window match independent HLS C++ scores exactly. The old x6
golden fails at window 12 against the new input stream. The reused Verilator
binary is from the prior amphp qualification; every current RTL/header/ROM
and testbench hash matches its archived compile manifest, including runtime
ROM contents. No generated core or wrapper source was edited.
`native_reference_logs.tar.gz` retains the reference and numerical logs.

Mac C++ retains the prior build-only libc++ header overlay. Server validation
will independently rebuild with original Vitis headers. System/gateware
qualification will be recorded as those stages complete.
