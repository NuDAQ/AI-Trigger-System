library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package AI_TRIGGER_PKG is

    -- CNN cluster configuration
    constant N_LANES    : integer := 5;    -- parallel CNN cores
    constant N_CH       : integer := 4;    -- ADC channels
    constant N_BATCH_S  : integer := 16;   -- samples per channel per batch
    constant N_BATCHES  : integer := 16;   -- batches per chunk (16 * 16 = 256 timesteps)
    constant N_CHUNK_W  : integer := 256;  -- total CNN input words per chunk
    constant N_CHUNK_BEATS_CNN : integer := 128;  -- two timesteps per 128-bit CNN beat
    constant CHUNK_ID_WIDTH : integer := 16;
    constant RAW_ADC_BATCH_WIDTH : integer := N_CH * N_BATCH_S * 12;
    constant WAVEFORM_RING_DEPTH : integer := 64;
    constant EVENT_CHUNKS : integer := 3;
    constant CHUNK_ID_FIFO_ADDR_WIDTH : integer := 5;
    constant CHUNK_ID_FIFO_DEPTH : integer := 2 ** CHUNK_ID_FIFO_ADDR_WIDTH;
    constant TRIGGER_FIFO_ADDR_WIDTH : integer := 5;
    constant TRIGGER_FIFO_DEPTH : integer := 2 ** TRIGGER_FIFO_ADDR_WIDTH;

    -- ADC data types: 4 channels, 16 samples per batch, 12-bit per sample
    subtype adc_sample_t  is std_logic_vector(11 downto 0);
    type    adc_row_t     is array (0 to N_BATCH_S - 1) of adc_sample_t;
    type    adc_data4_t   is array (0 to N_CH - 1)      of adc_row_t;
    subtype chunk_id_t     is unsigned(CHUNK_ID_WIDTH - 1 downto 0);
    subtype raw_adc_batch_t is std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
    type chunk_id_arr_t is array (0 to N_LANES - 1) of chunk_id_t;

    -- Per-lane busy flags (CLK_ADC domain)
    type lane_busy_t is array (0 to N_LANES - 1) of std_logic;

end package AI_TRIGGER_PKG;
