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

Mac C++ retains the prior build-only libc++ header overlay. Server validation independently rebuilt with original Vitis 2022.2 headers;
all six reference data-file hashes match the local build. All nine real-XPM
system cases pass in Vivado 2022.2: continuous, gaps/phase, positive/negative/
extreme thresholds, lane resets/backpressure, modes and overload. The gated
raw window gives 18002/1024=17.580078125; external words 281/282 respectively
accept/reject it. A valid old-threshold negative control fails at mode 4,
with zero events after one CNN result.

Existing SV string-concatenation file paths were not read correctly by XSim
2022.2. The three system fixtures now use formatted paths and reject missing/
unknown reference data before simulation. These are test-only changes. The
initial failed runs are retained and are not counted as numerical passes.
OOC's Bender child uses a task-local wrapper that clears Vivado's old C++
library path; the launcher prefixes that wrapper after Vivado startup. No
installed tool or shell profile was changed.

OOC implementation also passes in Vivado 2022.2, KU5P -2, with unchanged
ADC/CNN 250/200 MHz constraints: WNS +0.020 ns, WHS +0.024 ns,
TNS/THS zero. All 23 current trigger RTL hashes match the OOC source manifest.
`server/` retains per-case and routed reports, source provenance, and original
header reference metadata. Gateware qualification will follow this validated
trigger implementation.
