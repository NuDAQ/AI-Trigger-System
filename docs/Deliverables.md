# AI Trigger System

## Introduction

This version of the system receives 8 channels of 1 Gsa/s data. After
inference, it internally compares CNN scores with the configured threshold,
retains only events above threshold, and outputs the original waveform samples
with a timestamp. The intended delivery model is a black-box CNN-trigger block
with `CLK_ADC`, the clock arriving from the frontend ADC side, and `CLK_CNN`,
the CNN inference clock.

The delivered top-level interface has three groups:

- Upstream ADC input, synchronous to `CLK_ADC`
- Downstream event output, synchronous to `CLK_ADC`
- Clock/reset/configuration inputs: `CLK_CNN`, `RST`, and `CNN_THRESH`

## Upstream ADC Input Format

The upstream ADC-side logic drives the AI Trigger System directly with a
250 MHz `CLK_ADC`. No separate source clock, async FIFO, or gearbox is required
at the AI Trigger System boundary.

Each accepted input beat contains:

```text
8 channels x 4 samples/channel x 12 bits/sample = 384 bits
```

At 250 MHz, four samples per channel per beat sustains:

```text
250 MHz x 4 samples/beat = 1 Gsa/s/channel
```

The top-level packing convention is:

```text
ADC_DATA[(ch * 4 + sample) * 12 + 11 : (ch * 4 + sample) * 12]
  = raw 12-bit signed ADC sample for channel ch, sample index sample
```

The external interface uses clean 12-bit signed samples. It does not use a
16-bit sample container and does not require low-bit zero padding.

### Upstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_ADC` | in | 250 MHz frontend ADC clock used for input and event output. |
| `DATA_STR` | in | Input beat valid. When `1`, the trigger system accepts `ADC_DATA`. Continuous input may hold this high every `CLK_ADC` cycle. |
| `ADC_DATA[383:0]` | in | One ADC beat: 8 channels x 4 samples/channel x 12 bits/sample. |

There is no upstream `ADC_READY` backpressure signal. When `DATA_STR=1`, the
trigger system must synchronously accept the beat. When `DATA_STR=0`, the beat
is invalid and must not advance chunk assembly, timestamp generation, waveform
ring writes, or lane FIFO writes.

## Trigger Function

The system reduces data volume by retaining only CNN-triggered waveform events.
The current version has only the CNN trigger wrapper path; forced triggers,
Hi-Lo triggers, and pre/post-trigger windows are outside this version. The CNN
trigger path uses channels 0-3 for inference. Event output preserves all 8 raw
ADC channels in the same 384-bit beat format as the input interface.

CNN chunks remain 256 samples/channel. With four samples/channel per `CLK_ADC`
beat, one chunk spans:

```text
256 samples/channel / 4 samples per beat = 64 CLK_ADC beats
```

Inside the trigger block, ADC-domain aggregation groups the 4-sample beats into
the 256-sample CNN window as a pipeline. This preserves continuous input
throughput and keeps chunk id/timestamp metadata aligned with the data sent to
the CNN trigger.

## System and Control Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_CNN` | in | CNN inference clock, target 200 MHz. |
| `RST` | in | Active-high reset for the trigger system. |
| `CNN_THRESH[31:0]` | in | Trigger threshold configuration. Only bits `[21:0]` are interpreted as signed `ap_fixed<22,11>` raw threshold data. |

`RST` remains the delivered top-level reset input. Internally, reset release is
synchronized into the `CLK_ADC` and `CLK_CNN` domains. Reset must clear state
machines, FIFO/ring pointers, metadata-valid flags, and output-valid flags so
release cannot create a false chunk or false event.

`CNN_THRESH` is a single global CNN trigger threshold, not a per-channel,
per-lane, or per-class setting. It is a configuration input consumed in the
`CLK_CNN` domain after a configuration CDC path. A threshold update takes effect
on a CNN chunk boundary: the CNN-domain control path latches a threshold
snapshot when starting a 256-sample chunk and uses that snapshot for the full
chunk decision.

## Downstream Event Output Format

The event stream is a `CLK_ADC` ready/valid interface. It uses the same beat
shape and packing as `ADC_DATA`:

```text
EVENT_DATA[(ch * 4 + sample) * 12 + 11 : (ch * 4 + sample) * 12]
  = raw 12-bit signed ADC sample for channel ch, sample index sample
```

For the current one-chunk event window, each event emits only the triggered
chunk itself: 64 `EVENT_VALID` beats, no pre-trigger chunk, and no post-trigger
chunk. `EVENT_TIMESTAMP` is a chunk-index timestamp and remains constant across
those 64 beats. `EVENT_LAST` is asserted on the final beat.

### Downstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `EVENT_VALID` | out | Current event beat is valid. `0` is the normal idle state when no event data is available. |
| `EVENT_READY` | in | DAQ can accept the current event beat. This describes peak sink capability, not the normal average event rate. |
| `EVENT_DATA[383:0]` | out | Original waveform beat, in the same format as `ADC_DATA`. |
| `EVENT_LAST` | out | Last beat of the current event. |
| `EVENT_TIMESTAMP[23:0]` | out | Chunk-index timestamp, constant for all beats of one event. |

The delivered event interface does not expose CNN score, chunk id, overflow
counters, or trigger debug pulses.

DAQ-side sampling contract:

```text
if EVENT_VALID && EVENT_READY:
    read EVENT_DATA
    read EVENT_TIMESTAMP
    if EVENT_LAST:
        event finished
```

## Clock-Domain Boundary

`CLK_ADC` owns both the upstream input and the downstream event output. The trigger system boundary, therefore, does not need to solve a separate upstream or downstream clock-domain crossing. The remaining internal clock-domain crossings are the data/metadata path from `CLK_ADC` to `CLK_CNN` and the trigger descriptor path from `CLK_CNN` back to `CLK_ADC`. Configuration values such as `CNN_THRESH` also require explicit control/configuration CDC before use in the CNN domain; they are not part of the high-speed sample/event data path.
