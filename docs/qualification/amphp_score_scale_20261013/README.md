# amphp native score adaptation

Status: the minimal score adaptation passes local tests, all nine Vivado
actual-XPM system scenarios, and routed AI_TRIGGER_TOP OOC qualification.
The validated implementation and system fixtures are commit `e9eab03` on
`v4.0`. Subsequent interface documentation and the core header comment describe
the same behavior; they do not change synthesized logic.

The amphp core returns signed low 21 bits with unit 1/1024. The system now
compares those scores with the unchanged signed 32-bit external threshold
unit 1/16. Equality rejects, and negative values and the complete external
range remain supported. The only production behavior change is
`CNN_SCORE_FRAC_BITS: 9 -> 10`; gain remains six, and wrapper ports, input
packing, scheduling, raw event samples and gateware are unchanged.

| Validation | Result |
| --- | --- |
| Trigger decision TDD | Equality at score 2.0 / threshold 2.0 fails before the change, then passes |
| Arbiter boundaries and backpressure | New native units, one-LSB edges, signed extremes and raw score transport pass |
| GHDL regression | 39/39 benches pass |
| Native Python checks | 4/4 tests pass with the generated reference enabled |
| ADC conversion reference | All 4096 signed input codes checked; existing x6 conversion retained |
| Real CNN / Verilator | 1096/1096 ADC-aware scores and one gated-window score match HLS C++ exactly |
| Old model negative control | First zero window rejects old golden `001ff9c3`; new result is `001ff787` |
| Local / server HLS C++ | All six reference data-file hashes match |
| Vivado system regression | Continuous, gaps/phase, positive/negative/extreme thresholds, reset, modes and overload: 9/9 pass |

The old /512 system checker expected 179 positive-threshold events while the
new RTL correctly produced 143. After adapting the independent /1024 checker,
the case passes. The new gated raw window score is `33912/1024=33.1171875`;
external threshold words 529 and 530 respectively accept and reject it.

OOC uses Vivado 2023.2, `xcku5p-ffvb676-2-e`, and the unchanged 250 MHz ADC /
200 MHz CNN constraints. Overall setup WNS is +0.231 ns, hold WHS +0.004 ns,
and TNS/THS zero. CNN setup WNS is +0.309 ns. All 130039 routable nets are
fully routed, with zero routing errors, missing clocks or unconstrained
internal endpoints. CDC reports 261 safe and zero unsafe/unknown endpoints.
DRC retains generated-IP pipelining and unused-net warnings; no Error or
Critical Warning violations are present. RST remains the intentionally
false-pathed input without an input-delay requirement.

| Routed resource | Used |
| --- | ---: |
| LUT | 74868 (34.51%) |
| FF | 52062 (12.00%) |
| DSP | 64 |
| BRAM tiles | 21 |
| URAM | 6 |

`summary.json` identifies the dependency revisions, server directory, exact
RTL source checks, results and resources. All 27 trigger/flow files in the
server OOC source manifest match their committed blobs at `e9eab03`.
The server used a separate source/dependency snapshot, leaving its ordinary
checkouts and gateware intact. The routed checkpoint remains in that server
directory under `ooc/checkpoints/post_route.dcp`.

`local/` preserves red/green logs, the Verilator source closure and compiler
reference parity. `reference/` contains the new scores, ADC table and hashes.
`server/` preserves the completed simulation summary, per-case source
manifests/logs, and routed timing, CDC, DRC and resource reports.

Local C++ uses a build-only libc++ namespace overlay for unused complex
specializations; no dependency headers were edited. The server independently
uses the original Vitis headers. Verilator uses byte-identical generated RTL
in a path without spaces with `--converge-limit 10000`.

To repeat the local behavioral checks:

```sh
python3 scripts/run_ghdl_tests.py
AI_NATIVE_REFERENCE=/path/to/generated/reference python3 -m unittest discover -s tests -p 'test_native*.py'
```

Generate a fresh ADC-aware reference with `scripts/build_native_reference.py`
using the amphp NPZ, current core and Vitis headers. Test the native ports with
`tests/tb_native_core.sv`. The exact compile command and source hashes are in
`local/native-source-manifest.json`. On Linux with Vivado and Bender available:

```sh
python3 scripts/run_native_qualification.py --reference /path/to/generated/reference --output /path/to/empty/simulation
python3 scripts/run_vivado_build.py --impl --threads 4 --out-dir /path/to/empty/ooc
```

This qualifies the trigger subsystem's numerical behavior and OOC timing.
It is not a full gateware implementation, bitstream or physical-board test.
Scanning, plotting and delivery-tool migration is outside this minimal change.
