# Native two-lane evidence snapshot

Final qualification on 2026-09-17, Vivado/Vitis HLS 2023.2, Ubuntu 22.04.5,
`AI_TRIGGER_TOP`, `xcku5p-ffvb676-2-e`. The RTL behavior is revision
`8002ae318674b686b8f0f4fb9bf4bcf9e2d0b7f1`; later documentation-only differences
are explicitly audited. See [the qualification report](../../NativeCNNQualification.md)
for the contract, results, constraints and reproduction commands.

## Contents

- `post_route_*.rpt`: original final OOC timing, resources, route status,
  CDC, DRC and constraint coverage reports.
- `ooc_source_manifest.json`: exact source hashes recorded before the OOC run.
- `simulation_summary.json`: five completed, passing actual-IP / actual-XPM cases.
- `simulation/<case>/`: original simulator transcripts and source manifests.
- `reference.json`: additive corpus counts, ADC-aware reference generation,
  firmware hashes, supplied NPZ hash and reference-output hashes.
- `source_audit.json`: comparison with the local Bender source closure,
  verification of reference inputs/outputs, and routed checkpoint SHA256.
- `ghdl.log` and `python.log`: final local suites, 39 and 70 passing tests.
- `adc_conversion_4096.log`: VHDL conversion checked against all 4096 native fixed-point reference values.
- `SHA256SUMS`: hashes of the evidence files, excluding this checksum file.

The source audit records two text differences: ordinary comments in
`ADC_CHUNK_DISTRIBUTOR.vhd` (all non-comment lines identical), and a lane-count
display string in the legacy `tb_ai_trigger_top.sv`, which none of these
qualification cases elaborates. Selected native testbenches and all other
compiled sources match. Native RTL headers and ROM data are included in the
Bender manifests.

Full working artifacts remain in the local ignored directory
`build/native_validation/`. The isolated server workspace is
`/home/work1/Works/_codex_ai_trigger_native_20260917`, with final runs in
`qualification-qualified/` and `ooc-qualified/`. Earlier failed, interrupted
or superseded runs are not used for this snapshot. Large checkpoints and
generated stimulus data are not committed.

This is subsystem OOC evidence. Boundary input hold paths are excluded and
clock arrival is ideal; board clocks, upstream hold timing, gateware integration,
physical ADC calibration and activity-based power are not qualified here.
