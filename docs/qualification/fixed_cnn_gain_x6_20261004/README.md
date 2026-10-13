# Fixed CNN input gain x6

Branch: `v3.6`. Starting point: `8e2ee979c651dc28a9d477ea60562bdc9f70569c`.
RTL change: `cdeee8c`; normalized fixture adaptation: `02a5f9f`.
Status: local numerical, GHDL and generated-CNN RTL checks pass. All nine
server Vivado actual-XPM system cases pass, and routed OOC meets the unchanged
250/200 MHz constraints.

## Behavior and scope

`AI_TRIGGER_PKG.adc_to_axis16()` applies the fixed `CNN_INPUT_GAIN=6` before
native quantization and symmetric saturation. The full 12-bit product and
rounding bias fit in a signed 15-bit intermediate. For this even gain the
result is exactly `q=clamp(3*raw,-511,511)`; the model sees `q/32`.

Continuous AI converts live ADC batches. Hi-Lo gated AI first evaluates raw
samples, then converts the selected raw ring-buffer window during replay.
Hi-Lo input, thresholds in raw ADC units, ring storage, event samples, channel
ordering, clocks and pipeline latency are unchanged. Production RTL changes
are confined to the package's conversion function and one named constant.

This is a fixed bench configuration. Future online gain must be captured at
CNN-window admission and held for all 256 samples, before conversion. It will
need an explicit configuration interface and suitable intermediate width;
the current constant does not provide runtime control.

## Input fixtures and independent references

CNN Core Generator data, model weights and its original golden tests are
unchanged. The system reference generator encodes normalized model inputs as
`raw=clip(rint(X*64/6),-2048,2047)`. The generated HLS C++ receives the exact
reconstructed value `6*raw/64`, so ADC quantization is accounted for without
inflating normalized noise by six. Original score/event counts are not reused
as expectations for these newly quantized inputs.

Physical CSVs retain their voltage amplitude and the 0.8 Vpp ADC mapping.
Gain occurs after ADC quantization. With gain six the model input step is
`3/32`; the approximate symmetric input-voltage limit is 33.3 mV.

The 4096-code table comes independently from the generated native
`ap_fixed<10,5,AP_RND,AP_SAT_SYM>` type. Literal worked examples exercise odd
codes, sign extension, full-scale ADC codes and the +/-170/171 clipping edge.
The gated raw fixture is retained; its new native score is
`121370/512=237.05078125`. External threshold words 3792 and 3793 bracket it.

## Local evidence

| Check | Result |
| --- | --- |
| TDD conversion | Fails before implementation at raw=-171; then passes |
| Normalized fixture encoding | Red then green; model 1 maps to raw 11 |
| GHDL regression | 39/39 benches pass, including raw Hi-Lo and event paths |
| Python regression | 93/93 tests pass |
| Independent ADC conversion table | All 4096 signed raw codes match RTL |
| Verilator / normalized fixtures | 1096/1096 native CNN scores match HLS C++ |
| Verilator / physical templates | 2980/2980 native CNN scores match HLS C++ |
| Verilator / gated raw window | 1/1 native CNN score matches HLS C++ |

The four supplied `noise_2mV_for_x480` templates have 1000 samples each and
745 overlapping windows, with only channel zero populated. Noise RMS is
computed from the separately converted noisy/noiseless records, over all
1000 samples.

| Template | Physical noise RMS (mV) | CNN noise RMS | Clipped samples |
| --- | ---: | ---: | ---: |
| 2 sigma | 2.0361 | 0.9771 | 0 |
| 3 sigma | 2.1110 | 1.0147 | 0 |
| 4 sigma | 2.0226 | 0.9727 | 0 |
| 10 sigma | 1.9598 | 0.9425 | 0 |

Source hashes and score summaries are retained beside this document. These
overlapping windows are numerical characterization, not independent-event
false-trigger probabilities or measured hardware rates.

Local C++ uses the existing HLS headers with a build-only libc++ namespace
overlay for unused `std::complex` specializations; arithmetic headers and
canonical dependency files are unchanged. The patch and hashes are retained.
Verilator uses byte-identical generated RTL in a temporary path without
spaces, with `--converge-limit 10000` for 2229 HLS initialization delta delays.
Its testbench observes the native CNN ports; it does not include vendor XPMs.
Local GHDL uses the existing test support models. The separate Vivado results
below cover actual XPM integration and routed timing.

## Vivado system and routed OOC evidence

Vivado/Vitis HLS 2023.2 ran in an isolated source snapshot on `100.71.11.92`,
at implementation commit `149506e`, with the exact three Bender lockfile pins.
Existing server checkouts were not used as mutable build inputs. All six
reference assets generated with official Linux HLS headers are byte-identical
to the local reference assets, including every ADC code and expected score.
Production source hashes match between all nine simulation cases, routed OOC
and the local checkout; manifests and parity checks are retained.

| Actual native-IP / XPM case | Result |
| --- | --- |
| Continuous, threshold 0 | 1096 exact scores; 474 complete events |
| Input gaps and clock phase offset | 1096 exact scores; 474 complete events |
| Threshold +2 / -2 | 428 / 628 complete events |
| Minimum / maximum threshold words | 1096 / 0 complete events |
| Lane resets and held results | Pass |
| Capture-All, external, Hi-Lo, Hi-Lo gated AI | Pass; raw event samples preserved |
| Gated adjacent thresholds and mode switch | Pass; threshold snapshot preserved |
| Overload and recovery | Pass; loss reported, then 1096 exact scores and 474 events |

System and mode benches compare every accepted event beat with the original
eight-channel ADC words, including event-sink stalls. Hi-Lo still uses raw
threshold 100 in the mode fixture. Its original raw +/-200 excursions are
unchanged; only the selected CNN window receives gain six.

| Routed OOC metric | Result |
| --- | ---: |
| ADC setup WNS / hold WHS | +0.415 / +0.042 ns |
| CNN setup WNS / hold WHS | +0.250 / +0.004 ns |
| Overall TNS / THS | 0 / 0 ns |
| Overall pulse-width slack | +1.300 ns |
| LUT / FF | 61302 / 45589 |
| BRAM tiles / URAM / DSP | 21 / 6 / 128 |
| CDC unsafe / unknown endpoints | 0 / 0 |
| Missing clocks / unconstrained internal endpoints | 0 / 0 |
| DRC errors | 0 |

Relative to the pre-gain Hi-Lo v3 routed baseline, LUT/FF increase by 276/1;
DSP, BRAM and URAM counts are unchanged. Routed results depend on placement
and are not a guarantee of better timing for later gateware integration.
DRC retains 559 warnings: 302 DSP input-pipeline, 128 DSP PREG, 128 DSP MREG,
and one no-routable-load warning. The complete DRC and CDC reports are saved.

The routed checkpoint is preserved on the server and locally under ignored
`build/x6_gain_20261004/post_route.dcp`; its SHA256 and server path are in
`server_ooc/summary.json`. `SHA256.json` covers this qualification directory.
This qualifies the block; gateware integration and board validation remain
separate work.

## Reproduction

Use a fresh output directory and the pinned CNN Core plus Vitis HLS 2023.2
headers. The fixed gain is recorded in the new reference manifest.

```sh
python3 scripts/run_ghdl_tests.py
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/build_native_reference.py \
  --core-root "$CNN_CORE_ROOT" --hls-include "$HLS_INCLUDE" \
  --npz data/verification_data_2cv_k5s3_f12_es0.npz \
  --output build/x6_gain_20261004/server_reference
python3 scripts/run_ghdl_tests.py tb_cnn_input_conversion \
  --generic "REFERENCE_FILE=$PWD/build/x6_gain_20261004/server_reference/adc_conversion.txt"
python3 scripts/run_native_qualification.py \
  --reference build/x6_gain_20261004/server_reference \
  --output build/x6_gain_20261004/server_simulation \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado
python3 scripts/run_vivado_build.py --impl --min-setup-slack 0.0 \
  --out-dir build/x6_gain_20261004/server_ooc \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado
```

The OOC target remains `xcku5p-ffvb676-2-e` at ADC/CNN 250/200 MHz, with
unchanged constraints and a nonnegative setup-slack gate. Gateware integration
and board behavior require their own qualification.
