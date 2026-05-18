library ieee;
use ieee.std_logic_1164.all;

package AI_TRIGGER_PKG is

    -- CNN cluster configuration
    constant N_LANES    : integer := 7;    -- parallel CNN cores
    constant N_CH       : integer := 4;    -- ADC channels
    constant N_BATCH_S  : integer := 16;   -- samples per channel per batch
    constant N_BATCHES  : integer := 16;   -- batches per chunk (16 * 16 = 256 timesteps)
    constant N_CHUNK_W  : integer := 256;  -- total CNN input words per chunk

    -- ADC data types: 4 channels, 16 samples per batch, 12-bit per sample
    subtype adc_sample_t  is std_logic_vector(11 downto 0);
    type    adc_row_t     is array (0 to N_BATCH_S - 1) of adc_sample_t;
    type    adc_data4_t   is array (0 to N_CH - 1)      of adc_row_t;

    -- Per-lane busy flags (CLK_ADC domain)
    type lane_busy_t is array (0 to N_LANES - 1) of std_logic;

end package AI_TRIGGER_PKG;
