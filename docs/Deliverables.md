# AI Trigger System

## Introduction

This version of the system receives 8 channels of 1 Gsa/s data. After inference, it internally compares the CNN scores with the configured CNN threshold, retaining only events above the threshold and outputting them along with their timestamps in the same format. The goal is to significantly reduce data traffic. At the moment, you can take it as a black box.



## Desired upstream data format

The system prefers upstream data to be clocked at 62.5 MHz (16 ns), with 16 samples (1 pack) per clock cycle (16 samples/16ns = 1 sample/ns = 1 Gsa/s), buffered in a FIFO. Each pack is formed as `[63:0][7:0]`. 

The upstream can buffer 1 Gsa/s of data in the FIFO using different configurations without any issues, because the system interface backend samples 16 samples per clock cycle at a 70 MHz clock rate. 

```
[11: 0] = ch0
[23:12] = ch1
[35:24] = ch2
[47:36] = ch3
[63:48] = unused
```





