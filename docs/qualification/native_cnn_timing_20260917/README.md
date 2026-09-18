# Native two-lane timing optimization

Qualified RTL: `ba888f65a7b3e03f6ef92c63167366c075880181`.
Vivado 2023.2, `xcku5p-ffvb676-2-e`, ADC/CNN clocks 250/200 MHz.
The CNN IP, wrapper, dependency pins and all 35 dependency RTL/header/ROM
assets are unchanged. The OOC clock and exception constraints are unchanged.

## Change and measured result

`GATED_CNN_READER` prepares work metadata while waiting for admission and
captures the current threshold on the grant edge. `EVENT_RECORDER` prepares
read addresses and metadata independently of admission. Their valid signals
retain the original check/credit/grant conditions. This removes wide register
enables from the control paths without adding pipeline latency, changing
window expiration or changing the issue cadence.

| Measurement | Integration baseline | Gated metadata only | Final, both changes |
| --- | ---: | ---: | ---: |
| ADC setup WNS (ns) | 0.041 | 0.181 | 0.300 |
| CNN setup WNS (ns) | 0.191 | 0.219 | 0.382 |
| Overall hold WHS (ns) | 0.032 | 0.007 | 0.007 |
| Pulse-width WPWS (ns) | 1.300 | 1.300 | 1.300 |
| Requested 0.200 ns setup margin | Fail | Fail | Pass |

Final resources: 60,868 LUT, 45,518 FF, 128 DSP, 21 BRAM tiles, 6 URAM.
The increase from baseline is 17 LUT and 7 FF. All 107,883 routable nets
are routed, with zero routing errors. CDC has 253 safe endpoints and zero
unsafe/unknown/critical crossings. DRC has zero errors; the same 558 DSP
pipeline recommendations and one no-routable-load warning remain.
Setup/hold/pulse-width failing endpoints are all zero.

Hold margin decreased to 7 ps and remains positive in this OOC run. Boundary
input hold paths are excluded and clock arrival is ideal. This is block
qualification; full-board clocks and integration timing need separate checks.

## Functional and provenance checks

- 39 GHDL and 71 Python tests passed. Existing adjacent-event coverage checks
  130 events without output bubbles.
- All five actual-IP/XPM cases passed. Continuous and gapped runs each check
  1096 exact scores and 475 complete eight-channel events; reset, overload
  recovery, other modes and runtime switching also pass.
- The native mode test now changes the threshold before the gated window
  becomes readable and again during replay. The accepted window uses the
  launch-time snapshot through the result.
- All 62 OOC source-manifest entries and all 65 entries per simulation case
  match the local checkout exactly. There are no comment-only exceptions.
- The unchanged ADC-aware reference is recorded in
  [the original reference manifest](../native_cnn_20260917/reference.json):
  96 built-in windows plus 1000 supplied NPZ windows.

`source_audit.json` records these identities. `SHA256SUMS` covers the evidence
files. The large routed checkpoint and full working artifacts remain under
local `build/timing_optimization/` and server
`/home/work1/Works/_codex_ai_trigger_native_20260917/`; final server run names
are `timing-ooc-02` and `timing-qualification-02`.

## Reproduction

Use the reference-generation and regression commands in
[NativeCNNQualification.md](../../NativeCNNQualification.md). The strengthened
physical gate is:

```bash
python3 scripts/run_vivado_build.py \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado \
  --impl --out-dir build/native_ooc --threads 8 \
  --min-setup-slack 0.2 --keep-tcl > build/native_ooc.log 2>&1
```

The default remains zero setup slack for existing callers. Negative hold or
pulse-width slack, critical CDC crossings and DRC errors still fail the build.
Per-clock reports retain the 20 worst setup paths for the next investigation.
