library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package AI_TRIGGER_PKG is

    -- CNN cluster configuration
    constant N_LANES    : integer := 5;    -- parallel CNN cores
    constant N_ADC_CH   : integer := 8;    -- raw ADC channels captured into events
    constant N_TRIGGER_CH : integer := 4;  -- leading channels used by the CNN trigger
    constant N_CH       : integer := N_ADC_CH; -- historical alias for raw ADC channels
    constant N_BATCH_S  : integer := 4;    -- samples per channel per ADC beat
    constant N_BATCHES  : integer := 64;   -- beats per chunk (64 * 4 = 256 timesteps)
    constant N_CHUNK_W  : integer := 256;  -- total CNN input words per chunk
    constant N_CHUNK_BEATS_CNN : integer := 128;  -- two timesteps per 128-bit CNN beat
    constant LANE_FIFO_WRITE_WIDTH : integer := N_BATCH_S * 64;
    constant LANE_FIFO_READ_WIDTH  : integer := 128;
    constant LANE_FIFO_WRITE_ADDR_WIDTH : integer := 7;
    constant LANE_FIFO_WRITE_DEPTH : integer := 2 ** LANE_FIFO_WRITE_ADDR_WIDTH;
    constant CHUNK_ID_WIDTH : integer := 16;
    constant RAW_ADC_BATCH_WIDTH : integer := N_ADC_CH * N_BATCH_S * 12;
    constant WAVEFORM_RING_DEPTH : integer := 64;
    constant EVENT_CHUNKS : integer := 1;
    constant TIMESTAMP_WIDTH : integer := 24;
    constant CHUNK_ID_FIFO_ADDR_WIDTH : integer := 5;
    constant CHUNK_ID_FIFO_DEPTH : integer := 2 ** CHUNK_ID_FIFO_ADDR_WIDTH;
    constant TRIGGER_FIFO_ADDR_WIDTH : integer := 5;
    constant TRIGGER_FIFO_DEPTH : integer := 2 ** TRIGGER_FIFO_ADDR_WIDTH;
    constant ADC_INPUT_FIFO_ADDR_WIDTH : integer := 7;
    constant ADC_INPUT_FIFO_DEPTH : integer := 2 ** ADC_INPUT_FIFO_ADDR_WIDTH;
    constant EVENT_OUTPUT_FIFO_ADDR_WIDTH : integer := 7;
    constant EVENT_OUTPUT_FIFO_DEPTH : integer := 2 ** EVENT_OUTPUT_FIFO_ADDR_WIDTH;

    -- ADC data types: 8 channels, 4 samples per beat, 12-bit per sample
    subtype adc_sample_t  is std_logic_vector(11 downto 0);
    type    adc_row_t     is array (0 to N_BATCH_S - 1) of adc_sample_t;
    type    adc_data4_t   is array (0 to N_ADC_CH - 1)  of adc_row_t;
    subtype chunk_id_t     is unsigned(CHUNK_ID_WIDTH - 1 downto 0);
    subtype timestamp_t    is unsigned(TIMESTAMP_WIDTH - 1 downto 0);
    subtype raw_adc_batch_t is std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
    type chunk_id_arr_t is array (0 to N_LANES - 1) of chunk_id_t;
    type timestamp_arr_t is array (0 to N_LANES - 1) of timestamp_t;

    -- Per-lane busy flags (CLK_ADC domain)
    type lane_busy_t is array (0 to N_LANES - 1) of std_logic;

end package AI_TRIGGER_PKG;
