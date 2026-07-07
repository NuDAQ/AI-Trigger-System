# AI Trigger System

## Introduction

This version of the system receives 8 channels of 1 Gsa/s data. After
inference, it internally compares CNN scores with the configured threshold,
retains only events above threshold, and outputs the original waveform samples
with a timestamp. The intended delivery model is a black-box trigger block with
one DAQ-facing interface clock and one CNN inference clock.

There are three interface groups:

- Upstream ADC input, synchronous to `CLK_ADC`
- Downstream event output, synchronous to `CLK_ADC`
- System/control inputs, including `CLK_CNN`, `RST`, and `CNN_THRESH`

## Upstream ADC Input Format

The upstream DAQ logic drives the AI Trigger System directly with a 250 MHz
`CLK_ADC`. No separate source clock, async FIFO, or gearbox is required at the
AI Trigger System boundary.

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

### Upstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_ADC` | in | 250 MHz DAQ-facing input and event-output clock. |
| `DATA_STR` | in | Input beat valid. When `1`, the trigger system accepts `ADC_DATA`. |
| `ADC_DATA[383:0]` | in | One ADC beat: 8 channels x 4 samples/channel x 12 bits/sample. |

## Trigger Function

The system reduces data volume by retaining only triggered waveform events. The
CNN trigger path uses channels 0-3 for inference. Event output preserves all
8 raw ADC channels in the same 384-bit beat format as the input interface.

CNN chunks remain 256 samples/channel. With four samples/channel per
`CLK_ADC` beat, one chunk spans:

```text
256 samples/channel / 4 samples per beat = 64 CLK_ADC beats
```

## System and Control Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_CNN` | in | CNN inference clock, target 200 MHz. |
| `RST` | in | Active-high reset for the trigger system. |
| `CNN_THRESH[31:0]` | in | Trigger threshold configuration. Only bits `[21:0]` are interpreted as signed `ap_fixed<22,11>` raw threshold data. |

## Downstream Event Output Format

The event stream is a `CLK_ADC` ready/valid interface. It uses the same beat
shape and packing as `ADC_DATA`:

```text
EVENT_DATA[(ch * 4 + sample) * 12 + 11 : (ch * 4 + sample) * 12]
  = raw 12-bit signed ADC sample for channel ch, sample index sample
```

For the current one-chunk event window, each event emits 64 `EVENT_VALID`
beats. `EVENT_TIMESTAMP` remains constant across those 64 beats, and
`EVENT_LAST` is asserted on the final beat.

### Downstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `EVENT_VALID` | out | Current event beat is valid. |
| `EVENT_READY` | in | DAQ can accept the current event beat. |
| `EVENT_DATA[383:0]` | out | Original waveform beat, in the same format as `ADC_DATA`. |
| `EVENT_LAST` | out | Last beat of the current event. |
| `EVENT_TIMESTAMP[23:0]` | out | Event timestamp, constant for all beats of one event. |

DAQ-side sampling contract:

```text
if EVENT_VALID && EVENT_READY:
    read EVENT_DATA
    read EVENT_TIMESTAMP
    if EVENT_LAST:
        event finished
```

## Clock-Domain Boundary

`CLK_ADC` owns both the upstream input and downstream event output. The trigger
system boundary therefore does not need to solve a separate upstream or
downstream clock-domain crossing. The remaining internal clock-domain crossings
are the data/metadata path from `CLK_ADC` to `CLK_CNN` and the trigger
descriptor path from `CLK_CNN` back to `CLK_ADC`.
