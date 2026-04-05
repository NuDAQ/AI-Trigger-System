library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

PACKAGE PRE_TRIGGER_pkg IS

    -- Per-channel sample batch: 32 samples of 12 bits (sample 31 = newest)
    type adc_data_type    is array (0 to 31) of STD_LOGIC_VECTOR(11 downto 0);

    -- 8-channel ADC array (used by HiLoPath)
    type adc_data8_type   is array (0 to  7) of adc_data_type;

    -- 4-channel ADC array (used by 4-ch Hi-Lo PreTrigger)
    type adc_data4_type   is array (0 to  3) of adc_data_type;

    -- Intra-batch window counters: 32 samples x 8-bit countdown
    type time_window_type is array (0 to 31) of unsigned(7 downto 0);

    -- Per-channel gate outputs: 32 time-bin gate bits per channel
    type gate8_type       is array (0 to  7) of STD_LOGIC_VECTOR(0 to 31);  -- 8-ch (legacy)
    type gate4_type       is array (0 to  3) of STD_LOGIC_VECTOR(0 to 31);  -- 4-ch Hi-Lo

    -- Multiplicity vectors: one bit per channel, 32 time bins
    type mult32_type      is array (0 to 31) of STD_LOGIC_VECTOR(0 to  7);  -- 8-ch (legacy)
    type mult4x32_type    is array (0 to 31) of STD_LOGIC_VECTOR(3 downto 0); -- 4-ch Hi-Lo

    -- Coincidence carry-over: one 8-bit counter per channel (4 channels)
    type carry4_type      is array (0 to  3) of unsigned(7 downto 0);

End package PRE_TRIGGER_pkg;
