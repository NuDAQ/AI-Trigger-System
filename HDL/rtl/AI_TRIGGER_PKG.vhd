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
    constant BEAT_OFFSET_WIDTH : integer := 6;
    constant LOGICAL_BEAT_WIDTH : integer := CHUNK_ID_WIDTH + BEAT_OFFSET_WIDTH;
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
    subtype beat_offset_t  is unsigned(BEAT_OFFSET_WIDTH - 1 downto 0);
    subtype timestamp_t    is unsigned(TIMESTAMP_WIDTH - 1 downto 0);
    subtype raw_adc_batch_t is std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
    type chunk_id_arr_t is array (0 to N_LANES - 1) of chunk_id_t;
    type timestamp_arr_t is array (0 to N_LANES - 1) of timestamp_t;
    type beat_offset_arr_t is array (0 to N_LANES - 1) of beat_offset_t;
    type score_arr_t is array (0 to N_LANES - 1) of std_logic_vector(31 downto 0);

    type logical_beat_t is record
        chunk_id    : chunk_id_t;
        beat_offset : beat_offset_t;
    end record;

    type event_request_t is record
        start_address   : logical_beat_t;
        event_timestamp : timestamp_t;
        trigger_offset  : beat_offset_t;
        score           : std_logic_vector(31 downto 0);
    end record;

    constant NULL_LOGICAL_BEAT : logical_beat_t := (
        chunk_id    => (others => '0'),
        beat_offset => (others => '0')
    );
    constant NULL_EVENT_REQUEST : event_request_t := (
        start_address   => NULL_LOGICAL_BEAT,
        event_timestamp => (others => '0'),
        trigger_offset  => (others => '0'),
        score           => (others => '0')
    );

    constant TRIGGER_MODE_CAPTURE_ALL : std_logic_vector(3 downto 0) := "0000";
    constant TRIGGER_MODE_EXTERNAL    : std_logic_vector(3 downto 0) := "0001";
    constant TRIGGER_MODE_AI          : std_logic_vector(3 downto 0) := "0010";
    constant TRIGGER_MODE_HILO        : std_logic_vector(3 downto 0) := "0011";
    constant TRIGGER_MODE_HILO_AI     : std_logic_vector(3 downto 0) := "0100";

    function add_beats(
        address_value : logical_beat_t;
        beat_count    : natural
    ) return logical_beat_t;

    function subtract_beats(
        address_value : logical_beat_t;
        beat_count    : natural
    ) return logical_beat_t;

    function adc_to_axis16(
        sample_value : adc_sample_t
    ) return std_logic_vector;

    function pack_cnn_batch(
        batch_value : adc_data4_t
    ) return std_logic_vector;

    function pack_cnn_raw_batch(
        batch_value : raw_adc_batch_t
    ) return std_logic_vector;

    -- Per-lane busy flags (CLK_ADC domain)
    type lane_busy_t is array (0 to N_LANES - 1) of std_logic;

end package AI_TRIGGER_PKG;

package body AI_TRIGGER_PKG is
    function unpack_logical_beat(
        flat_value : unsigned(LOGICAL_BEAT_WIDTH - 1 downto 0)
    ) return logical_beat_t is
        variable result : logical_beat_t;
    begin
        result.chunk_id :=
            flat_value(LOGICAL_BEAT_WIDTH - 1 downto BEAT_OFFSET_WIDTH);
        result.beat_offset :=
            flat_value(BEAT_OFFSET_WIDTH - 1 downto 0);
        return result;
    end function;

    function add_beats(
        address_value : logical_beat_t;
        beat_count    : natural
    ) return logical_beat_t is
        variable flat_value : unsigned(LOGICAL_BEAT_WIDTH - 1 downto 0);
    begin
        flat_value := address_value.chunk_id & address_value.beat_offset;
        flat_value := flat_value + to_unsigned(beat_count, LOGICAL_BEAT_WIDTH);
        return unpack_logical_beat(flat_value);
    end function;

    function subtract_beats(
        address_value : logical_beat_t;
        beat_count    : natural
    ) return logical_beat_t is
        variable flat_value : unsigned(LOGICAL_BEAT_WIDTH - 1 downto 0);
    begin
        flat_value := address_value.chunk_id & address_value.beat_offset;
        flat_value := flat_value - to_unsigned(beat_count, LOGICAL_BEAT_WIDTH);
        return unpack_logical_beat(flat_value);
    end function;

    function adc_to_axis16(
        sample_value : adc_sample_t
    ) return std_logic_vector is
        variable raw_value    : signed(11 downto 0);
        variable scaled_value : signed(11 downto 0);
        variable fixed_value  : signed(8 downto 0);
    begin
        raw_value := signed(sample_value);
        scaled_value := shift_right(raw_value, 1);
        if scaled_value > to_signed(255, scaled_value'length) then
            fixed_value := to_signed(255, fixed_value'length);
        elsif scaled_value < to_signed(-256, scaled_value'length) then
            fixed_value := to_signed(-256, fixed_value'length);
        else
            fixed_value := resize(scaled_value, fixed_value'length);
        end if;
        return std_logic_vector(resize(fixed_value, 16));
    end function;

    function pack_cnn_batch(
        batch_value : adc_data4_t
    ) return std_logic_vector is
        variable packed_value :
            std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0) := (others => '0');
        variable segment_base : integer;
    begin
        for pair_idx in 0 to N_BATCH_S / 2 - 1 loop
            segment_base := pair_idx * 128;
            for row_in_pair in 0 to 1 loop
                for ch in 0 to N_TRIGGER_CH - 1 loop
                    packed_value(
                        segment_base + row_in_pair * 64 + ch * 16 + 15 downto
                        segment_base + row_in_pair * 64 + ch * 16
                    ) := adc_to_axis16(batch_value(ch)(2 * pair_idx + row_in_pair));
                end loop;
            end loop;
        end loop;
        return packed_value;
    end function;

    function pack_cnn_raw_batch(
        batch_value : raw_adc_batch_t
    ) return std_logic_vector is
        variable unpacked_value : adc_data4_t :=
            (others => (others => (others => '0')));
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                unpacked_value(ch)(sample_idx) := batch_value(
                    (ch * N_BATCH_S + sample_idx) * 12 + 11 downto
                    (ch * N_BATCH_S + sample_idx) * 12
                );
            end loop;
        end loop;
        return pack_cnn_batch(unpacked_value);
    end function;
end package body AI_TRIGGER_PKG;
