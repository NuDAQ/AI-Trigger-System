# Stable CNN threshold interface

`CNN_THRESH[31:0]` is a signed 32-bit two's-complement configuration word with
four fractional bits. All 32 bits are meaningful. This system-owned interface
does not inherit the generated CNN IP's score width or binary point.

```text
threshold = signed(CNN_THRESH[31:0]) / 16
CNN_THRESH_raw = threshold * 16
```

| Property | Value |
| --- | --- |
| Minimum step | 0.0625 |
| Minimum threshold | -134217728 |
| Maximum threshold | 134217727.9375 |
| Comparison | Strictly `score > threshold`; equality does not trigger |
| Configuration lifetime | Snapshotted with each AI Work Item; later writes affect later work |
| Ports and clocks | Unchanged; configuration remains synchronous to `CLK_ADC` |

| Threshold | Signed register value | 32-bit word |
| ---: | ---: | --- |
| -2 | -32 | `FFFFFFE0` |
| -1 | -16 | `FFFFFFF0` |
| 0 | 0 | `00000000` |
| 0.0625 | 1 | `00000001` |
| 2 | 32 | `00000020` |
| 2.0625 | 33 | `00000021` |

Software should accept multiples of 0.0625 within the range above. A UI can
choose a coarser step, such as 0.25, 0.5 or 1, without changing this encoding.
An off-grid value needs an explicit caller policy; the hardware does not
silently round a requested real value because its input is already an integer.

## Native score adaptation

The current CNN still returns signed bits `[20:0]` in a 32-bit container, with
eleven zero padding bits. Its score unit remains 1/512 and its representable
range is -2048 through 2047.998046875. Score transport and CNN arithmetic are
unchanged; only the interpretation of the threshold configuration changes.

`AI_TRIGGER_PKG.cnn_score_above_threshold` owns the conversion used by both
`CNN_RESULT_ARBITER` and `TRIGGER_DECISION`. It sign-extends both operands and
shifts the external threshold left by five before a strict signed comparison.
The 37-bit comparison preserves the complete external range. There is no
multiplier, rounding, saturation, wraparound, or extra transaction latency.

A threshold below -2048 accepts every representable native score; a threshold
at or above 2048 rejects every representable native score. At exactly -2048,
an equal native score is still rejected. These are mathematical comparisons,
not special encodings. Backpressure, capacity loss, and Trigger Mode selection
retain their existing behavior.

On a future IP update, adapt the native score interpretation inside the system
while retaining this external unit, signedness, range, strict comparison, and
snapshot contract. Model updates can still require choosing a different useful
threshold; a fixed encoding does not promise unchanged model calibration.

## Migration

This is a deliberate one-time change from the earlier native threshold unit
1/512. For example, threshold 2.0 now uses **32**, not 1024 (native two-lane
format) or 4096 (older wrapper-v5 format). Zero remains zero. No automatic
format detection is performed, since the same integer is valid in each format.

The public `--threshold` option of `run_native_sim.py` and `--cnn-thresh-raw`
options of the other system simulation tools use this signed external word.
Native score CSVs and HLS reference files continue to use native score units.
