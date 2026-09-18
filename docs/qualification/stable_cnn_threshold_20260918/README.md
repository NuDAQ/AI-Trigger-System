# Stable external CNN threshold qualification

Status: accepted by the user on 2026-09-18 at the original clock constraints.
Qualified RTL is byte-for-byte equivalent to `5841b98` (threshold adaptation
only); the later read-address preparation experiment was reverted.
Vivado 2023.2 on Ubuntu 22.04.5, `xcku5p-ffvb676-2-e`.

## Interface and implementation

`CNN_THRESH[31:0]` is a signed two's-complement word with unit 1/16.
The step is 0.0625; threshold 2.0 is encoded as 32. The entire external range
is meaningful, from -134217728 through 134217727.9375. See the complete
[interface and migration contract](../../CNNThresholdInterface.md).

The system's shared numeric adapter sign-extends the native 21-bit score and
the external threshold, shifts the threshold by five, and compares at 37 bits.
This preserves native score precision, strict `score > threshold`, negative
thresholds, equality behavior and thresholds outside the native score range.
No rounding, saturation, multiplier or extra transaction latency is introduced.
Each work item still retains its threshold snapshot.

The existing gated-reader admission and address logic is retained. An experiment
that prepared the first address independently of admission did not improve the
route and was reverted. The additional extreme-threshold test cases remain.

The top-level port declaration, clocks, ADC representation, raw eight-channel
events, CNN arithmetic, wrapper and dependency pins remain unchanged. The
one-time threshold encoding migration is the deliberate external behavior change.

## Functional qualification

The local suite passes 39 GHDL and 73 Python tests. GHDL uses behavioral XPM
models; the server's native suite uses actual CNN RTL and vendor XPM models.

TDD failures were reproduced before implementation: the old comparator rejected
the external threshold interpretation, the native simulation CLI discarded
upper threshold bits, and the analyzer compared incompatible score/threshold
units. The focused red logs and final passing suite logs accompany this report.
Port-level comparisons cover equality and adjacent native LSBs, adjacent 0.0625
steps, negative thresholds, native score limits and both signed-32 extremes.

All nine actual-IP/XPM cases passed on this exact RTL. The initial seven-case
run and two additional extreme cases are combined in `simulation_summary.json`;
the current runner includes all nine by default. Results:

| Scenario | Observed result |
| --- | --- |
| Continuous, threshold 0 | 1096 exact scores, 475 complete events |
| ADC gaps and CNN phase offset | Same scores/events with gap 9 and phase 1.3 ns |
| Threshold +2 / -2 | 431 / 643 complete events from 1096 exact scores |
| Minimum / maximum external word | 1096 / 0 complete events from 1096 exact scores |
| Lane resets and stalls | Reset during partial input, computation and held output; metadata preserved |
| Other modes and snapshots | Capture-All, External, Hi-Lo and Hi-Lo-gated CNN; runtime mode switch |
| Sink overload and recovery | 36 returned scores, two retained complete events, then exact full-corpus recovery |

The gated reference score is -1495/512. Threshold -47/16 accepts it and -46/16
rejects it. Changing the live threshold after work admission must not change
that work's decision. Event checks include every raw data beat, timestamp,
trigger offset and LAST, including centered windows spanning chunk boundaries.

The unchanged ADC-aware corpus contains 96 built-in windows plus all 1000
supplied NPZ windows. Its reference was computed from the exact ADC-representable
inputs, using native HLS C++, and also includes all 4096 ADC conversion codes.
See the [reference manifest](../native_cnn_20260917/reference.json). The supplied
NPZ SHA256 is `c662edb897f09ea93de1f524b1ce12f00e54b9b028565d4d2082d4c1bb0b64a4`.

## Routed OOC qualification

Accepted OOC run: `threshold-ooc-01`. The clocks remain ADC 250 MHz / CNN 200 MHz.
All normal setup, hold and pulse-width constraints are met. The run originally
returned exit code 1 solely because the additional 0.200 ns setup-margin gate
was not met. After comparing the routes, the user accepted this version without
that additional margin requirement. The same timing and CDC reports pass the
existing gates with minimum setup slack 0.0. No XDC constraints were changed.

| Check | Result |
| --- | --- |
| ADC / CNN setup WNS | +0.191 / +0.310 ns |
| Overall hold WHS / pulse-width WPWS | +0.007 / +1.300 ns |
| Setup / hold / pulse-width failing endpoints | 0 / 0 / 0 |
| Fully routed nets / routing errors | 107,967 / 0 |
| LUT / FF | 60,862 (28.05%) / 45,547 (10.50%) |
| DSP / BRAM tiles / URAM | 128 (7.02%) / 21 (4.38%) / 6 (9.38%) |
| CDC | 261 safe endpoints; zero unsafe, unknown or critical crossings |
| DRC | Zero errors; 558 DSP pipeline recommendations and one no-routable-load warning |

| Version | ADC estimated minimum period | CNN estimated minimum period |
| --- | --- | --- |
| Before threshold adaptation | 3.700 ns | 4.618 ns |
| Accepted threshold adaptation | 3.809 ns | 4.690 ns |
| Rejected read-address experiment | 3.827 ns | 4.881 ns |

These period-minus-WNS estimates are not frequency-sweep qualification. The
accepted operating targets remain 4 ns / 5 ns. The small threshold adapter
changed whole-system mapping and routing; neither clock's worst path is in
the threshold comparator. Compared with the prior route, resources changed
by -6 LUT and +29 FF, with DSP/BRAM/URAM unchanged.

The initial threshold-adapter route met the clock constraints but failed the
margin gate at ADC +0.191 ns; CNN setup was +0.310 ns and hold was +0.007 ns.
Explore placement/routing produced the same margins. Post-route physical
optimization skipped this positive-slack design, as described in
[AMD UG835](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/phys_opt_design).
The experimental reports are retained. The accepted script uses the original
placement and routing commands. Temporary uncertainty changes were considered
but never implemented.

OOC boundary input/output delays are zero, input hold paths are excluded, clock
arrival is ideal, the clocks are asynchronous and external reset is false-pathed.
This qualifies the subsystem under its existing constraints; full-board timing,
physical ADC calibration, activity-based power and board validation are outside
this delivery. Power reports use default activity.

## Provenance and reproduction

`source_audit.json` verifies all 62 OOC manifest entries and all 65 entries per
simulation case against the restored checkout. All 35 dependency RTL/header/ROM
assets match the previous two-lane qualification; the top boundary matches
baseline `68b1e72` except comments. Reports, simulation logs and source manifests are retained here and
covered by `SHA256SUMS`. Full working artifacts and checkpoints remain on server
`/home/work1/Works/_codex_ai_trigger_native_20260917/`, in final run directories
`threshold-ooc-01`, `threshold-qualification-01` and `threshold-extremes-01`.
The later `threshold-ooc-03` and `threshold-qualification-02` runs describe the
reverted read-address experiment and are not used to qualify the accepted RTL.

Build the ADC-aware reference using the commands in
[NativeCNNQualification.md](../../NativeCNNQualification.md), then run:

```bash
python3 scripts/run_ghdl_tests.py
python3 -m unittest discover -s tests
python3 scripts/run_native_qualification.py \
  --reference build/native_reference \
  --output build/stable_threshold_qualification \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado
python3 scripts/run_vivado_build.py \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado \
  --impl --out-dir build/stable_threshold_ooc --threads 8 \
  --min-setup-slack 0.0 --keep-tcl > build/stable_threshold_ooc.log 2>&1
python3 scripts/package_delivery.py --version stable-threshold
```

Use empty output directories. Both vendor commands fail on incomplete execution;
the OOC flow also rejects insufficient setup margin, negative hold/pulse-width
slack, DRC errors, critical CDC crossings, black boxes and missing clocks.
