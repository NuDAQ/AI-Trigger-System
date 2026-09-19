# Hi-Lo v3.0.0 integration qualification

AI branch: `v3.5`. Starting point: `8fc95af8531f66738a289c95baee7230da82b59f`.
Qualified RTL/test snapshot: `713197b4e0e8` (later delivery/documentation changes
do not alter the implementation or native test inputs).
Status: local regression, all nine native scenarios and routed OOC passed.
Tools: GHDL 6.0.0 LLVM / Python 3.14.6 locally; Vivado 2023.2 on Ubuntu 22.04.5
for actual-IP/XPM simulation and implementation, device `xcku5p-ffvb676-2-e`.

## Release and scope

Published Hi-Lo tag `v3.0.0` resolves to
`047d14a25ca0df95d2219eded90e0b449574ae15`. Its complete tree matches the
standalone recovery checkpoint `58be92d8710e4e030b86643ea1827d223b86b344`.
Bender 0.32.1 uses the exact requirement `=3.0.0`; only `hilo-trigger` was
updated with `bender update hilo-trigger --fetch`. CNN wrapper and core remain
at `a82a717403c8346d027f62b017295d8ea6fa3344` and
`eca9b12f9f49f4b7324ed9ed241a44086ca9c842` respectively.

Both top-level window inputs are now unsigned 8-bit accepted-sample counts.
The width is derived from the dependency's package. The neutral dependency
type/port names are adapted at the existing boundary. Four accepted ADC beats
still form a 16-sample aggregate, with the fourth-beat anchor and original
result pipeline. Event length, sample ordering, partial-batch clearing, mode
control, blanking, loss handling and CNN thresholds are unchanged.

Standalone `BIN_THR=0` semantics are preserved in Hi-Lo. The pre-existing AI
wrapper policy still rejects that configuration; it was not redesigned.
Old in-range connections must be zero-extended to 8 bits. Wider windows now
retain their full value instead of the old core's silent clamps.

No gateware code, CNN dependency, FPGA constraints or placement/routing recipe
was changed. This is preparation for v3.5.0, not board integration or publication.

## Functional evidence

- 39 GHDL benches and 74 Python tests pass against locked dependency checkouts.
- The ADC conversion bench also passes with the verified native reference file
  for all 4096 signed raw codes (`native_adc_conversion.log`).
- Both `0011` and `0100` preserve configuration snapshots, the existing request
  latency and the triggering aggregate's centered-event metadata with Hi-Lo
  and coincidence windows of 255 accepted samples.
- Existing adapter, reset, valid-gap, invalid-configuration, busy/loss, blanking,
  gated capture and runtime-mode tests remain in the suite.
- TDD red logs show the old dependency-facing type failing compilation, the
  old simulation CLI rejecting 255, and missing Hi-Lo delivery provenance;
  the corresponding green logs are retained.

Core truth-table and old-capture regressions remain owned by Hi-Lo-Trigger,
in its `docs/qualification/v3.0/README.md`. They are not replaced by CNN tests.

The unchanged native reference contains 96 built-in windows plus all 1000
caller-supplied NPZ windows, and checks every 12-bit ADC code. The NPZ SHA256 is
`c662edb897f09ea93de1f524b1ce12f00e54b9b028565d4d2082d4c1bb0b64a4`.
Before reusing the reference, all 93 firmware files, the C++ harness, baseline
data and six reference assets were hash-verified against the locked core.
See `reference_audit.json` and the existing
[reference manifest](../native_cnn_20260917/reference.json).

## Native and physical results

All nine native cases completed with exit code zero. Counts match the accepted
[stable-threshold baseline](../stable_cnn_threshold_20260918/README.md):

| Scenario | Result |
| --- | --- |
| Continuous / ADC gaps and phase offset | 1096 exact scores and 475 complete events each |
| External threshold +2 / -2 | 431 / 643 complete events, all 1096 scores exact |
| Minimum / maximum external word | 1096 / 0 complete events, all 1096 scores exact |
| Lane reset and stalls | Partial-input, computation and held-output reset recovery pass |
| Modes and snapshots | Capture-All, External, Hi-Lo and gated AI pass; runtime switch passes |
| Sink overload and recovery | 36 returned scores, two retained events; then exact 1096-window recovery |

Gated AI retains the -1495/512 reference score, accepted at threshold -47/16
and rejected at -46/16, including threshold snapshots. Raw eight-channel event
data, timestamps, offsets and LAST are checked by the existing benches.

The unchanged OOC flow completed with exit code zero at ADC 250 / CNN 200 MHz:

| Check | Baseline | Hi-Lo v3 integration |
| --- | ---: | ---: |
| ADC / CNN setup WNS (ns) | +0.191 / +0.310 | +0.311 / +0.180 |
| Overall hold WHS / pulse-width WPWS (ns) | +0.007 / +1.300 | +0.007 / +1.300 |
| System LUT / FF | 60,862 / 45,547 | 61,026 / 45,588 |
| `u_PRE_TRIGGER` LUT / FF | 2,216 / 189 | 2,363 / 225 |
| `u_HILO` including controller LUT / FF | 2,275 / 388 | 2,422 / 429 |
| Four-to-sixteen adapter LUT / FF | 6 / 817 | 6 / 817 |
| DSP / BRAM tiles / URAM | 128 / 21 / 6 | 128 / 21 / 6 |

System growth is +164 LUT (+0.269%) and +41 FF (+0.090%). The core grows
by +147 LUT (+6.634%) and +36 FF (+19.048%). Both the 2% system and 25% core
review thresholds pass, with no new DSP/BRAM/URAM. ADC WNS improves by 0.120 ns;
CNN WNS decreases by 0.130 ns but remains positive. No unrelated RTL or
constraint changes were used to recover timing. Hold margin remains small.

All setup/hold/pulse-width failing-endpoint counts are zero. All 108,150
routable nets are fully routed, with zero routing errors. CDC remains 261 safe
endpoints and zero unsafe, unknown or critical crossings. DRC has zero errors;
the previous 558 DSP pipeline recommendations and one no-routable-load warning
remain. There are no unclocked registers, unconstrained internal endpoints or
combinational loops. Default-activity power is 3.065 W, not measured board power.

The inherited `MULT2BIN` incomplete sensitivity-list warning for `BIN_THR`
remains intentionally unchanged. The AI path uses latched stable configuration;
this qualification does not promise standalone live BIN_THR-only simulation
updates. Likewise, ideal parent-clock OOC warnings are retained, not suppressed.

`source_audit.json` matches all 62 OOC entries and all 66 entries in each native
case to the local locked checkout. All 31 CNN/wrapper RTL/header/ROM assets
and the OOC constraints are unchanged. The simulation closure has one more
entry than the baseline because v3.0 restores `tb_hilo_trigger.vhd` to its
dependency simulation manifest; native runs still select their own testbench.
`resource_comparison.json`, raw reports, red/green logs and native case logs
are retained here and covered by `SHA256SUMS`.

## Reproduction and boundaries

The isolated server snapshot is
`/home/work1/Works/ai-trigger-hilo-v35.lHAri7`. It contains locked Bender
checkouts, without `Bender.local`. Output directories are
`build/hilo-v3-native` and `build/hilo-v3-ooc`.

```sh
bender checkout
python3 scripts/run_ghdl_tests.py
python3 -m unittest discover -s tests
python3 scripts/run_native_qualification.py \
  --reference /path/to/verified/native_reference --output build/hilo-v3-native \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado
python3 scripts/run_vivado_build.py \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado --impl \
  --out-dir build/hilo-v3-ooc --threads 8 --min-setup-slack 0.0 --keep-tcl
python3 scripts/package_delivery.py --version v3.5.0
```

Use empty output directories. Generate a fresh ADC-aware reference with the
commands in [NativeCNNQualification.md](../../NativeCNNQualification.md) when
its source/data hashes differ. Native tests use actual CNN RTL and vendor XPM;
local GHDL tests use behavioral XPM models.

OOC input/output delays remain zero, input hold paths are excluded, clocks
are ideal and asynchronous, and external reset is false-pathed. This does not
qualify gateware's 260/195 MHz clocks, board IO timing, physical ADC calibration
or board operation. No unrelated logic may be changed merely to recover margin.
