Single-channel neutrino templates for bench tests  (A. Barletta, 2026-09-29)
===========================================================================

The same 59 simulated neutrino events as the full template sets (2, 3, 4 and 10 sigma; LPDAs at 1 m and 3 m; new LPDA
antenna model with the x2/x3 back-lobe scaling), reduced to ONE waveform per event for a setup that drives one channel.

EXAMPLE BUNDLE: 4 of the 59 events (one typical 3 m event per amplitude: 2, 3, 4 and 10 sigma, chosen as the event
whose 1-channel score is closest to the median of its group), files flat in this folder; manifest_examples.csv holds
their rows. Everything below describes the full set, which is available on request.

CHANNEL CHOICE: the channel with the largest pulse, i.e. the channel that defines the template's "N sigma" (peak |V| of
the noiseless 80-500 MHz trace / RMS of the added noise, +-5% bins). manifest column channel_used.

FILES (per event, e.g. nu_3m_2sigma_ev1)
  _noiseless.csv   the signal alone
  _noisy.csv       the same signal with the thermal noise used in CNN training added
  _scores.csv      CNN score for every 256-sample window (0-255, 1-256, ... 744-999) of the _noisy waveform played ALONE on
                   CNN input 0, with inputs 1-3 at zero (an open input)
  Format as before: 2 header lines ("x-axis,1" / "second,Volt"), 1000 rows of time [s], voltage [V], 1 ns steps from
  -100 ns; the pulse peaks at +400 ns, so a sliding scan starts and ends on pure noise.

MODEL: 2cv_k5s3_f12 trained on prod_p2_v1 (the model on the FPGA), fixed-point replica of the software model,
threshold 2.807 (set for noise on all 4 inputs at 1e-6 per 256-ns window).

manifest_single_channel.csv (one row per event)
  channel_used, sigma_this_channel, flavor, interaction, energy, weight
  score_4ch_typical, fire_frac_4ch   the event with all 4 channels (from the full set): median over 16 noise draws of the
                                     highest window score, and the fraction of draws above 2.807
  score_1ch_typical, fire_frac_1ch   the same for this ONE channel on input 0, inputs 1-3 at zero (16 new noise draws,
                                     windows containing the pulse peak)
  file_max_score_x80 / _x480         highest window score of the _noisy file at each scale (windows containing the peak)
  noise_rms_mV_x80 / _x480           RMS of the first 300 samples of the _noisy file at each scale

WHAT TO EXPECT with one channel (fraction of noise draws above 2.807, mean over events):
   2 sigma: 17% (4 channels: 91%)    3 sigma: 93% (100%)    4 and 10 sigma: 100% (100%)
  Typical scores are roughly half the 4-channel values, so the 50%-efficiency point is between 2 and 3 sigma.
  NOTE: 2.807 is the threshold for noise on all 4 inputs. With noise on one input only, noise alone fires less often at
  2.807, so a 1-channel setup can use a lower threshold for the same noise rate (being estimated separately).

THIS SET: noise_2mV_for_x480
  Noise ~2.1 mV RMS (flat 47 dB gain), the natural level of the amplifier. Intended for an FPGA input conversion of
  about V x 480 (= 80 x 6), so ~2.1 mV of noise reaches the CNN at ~1 like in training. The _scores.csv use the 12-bit
  ADC quantization then x480 (no 9-bit clamp, since how the x6 is implemented is not fixed yet).
