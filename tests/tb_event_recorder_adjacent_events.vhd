library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_recorder_adjacent_events is
end entity tb_event_recorder_adjacent_events;

architecture sim of tb_event_recorder_adjacent_events is
    constant EVENT_COUNT : integer := EVENT_OUTPUT_FIFO_DEPTH + 2;

    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal data_str             : std_logic := '0';
    signal adc_data4            : adc_data4_t := (others => (others => (others => '0')));
    signal request_valid        : std_logic := '0';
    signal request_ready        : std_logic;
    signal request_value        : event_request_t := NULL_EVENT_REQUEST;
    signal check_start_chunk_id : chunk_id_t;
    signal check_start_offset   : beat_offset_t;
    signal check_present        : std_logic;
    signal check_protected      : std_logic;
    signal check_expired        : std_logic;
    signal check_valid          : std_logic;
    signal rb_rd_en             : std_logic;
    signal rb_rd_chunk_id       : chunk_id_t;
    signal rb_rd_batch_idx      : integer range 0 to N_BATCHES - 1;
    signal rb_rd_data           : raw_adc_batch_t;
    signal rb_rd_valid          : std_logic;
    signal rb_rd_hit            : std_logic;
    signal recorder_valid       : std_logic;
    signal recorder_ready       : std_logic;
    signal recorder_data        : raw_adc_batch_t;
    signal recorder_last        : std_logic;
    signal recorder_chunk_id    : chunk_id_t;
    signal recorder_timestamp   : timestamp_t;
    signal recorder_offset      : beat_offset_t;
    signal recorder_score       : std_logic_vector(31 downto 0);
    signal event_credit         : std_logic;
    signal event_valid          : std_logic;
    signal event_data           : raw_adc_batch_t;
    signal event_last           : std_logic;
    signal event_chunk_id       : chunk_id_t;
    signal event_timestamp      : timestamp_t;
    signal event_offset         : beat_offset_t;
    signal event_score          : std_logic_vector(31 downto 0);

    procedure drive_batch(
        signal target : out adc_data4_t;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (beat_value + ch * 256 + sample_idx) mod 2048, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_ring : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK => clk, RST => rst, DATA_STR => data_str, ADC_DATA4 => adc_data4,
            CHUNK_COMMIT => open, COMMIT_CHUNK_ID => open, COMMIT_TIMESTAMP => open,
            WRITE_CHUNK_ID => open, WRITE_BEAT_OFFSET => open, WRITE_TIMESTAMP => open,
            CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET => check_start_offset,
            CHECK_PRESENT => check_present, CHECK_PROTECTED => check_protected,
            CHECK_EXPIRED => check_expired,
            RD_EN => rb_rd_en, RD_CHUNK_ID => rb_rd_chunk_id,
            RD_BATCH_IDX => rb_rd_batch_idx, RD_DATA => rb_rd_data,
            RD_VALID => rb_rd_valid, RD_HIT => rb_rd_hit
        );

    u_recorder : entity work.EVENT_RECORDER
        port map (
            CLK => clk, RST => rst,
            REQUEST_VALID => request_valid, REQUEST_READY => request_ready,
            REQUEST_VALUE => request_value,
            CHECK_VALID => check_valid, CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET => check_start_offset, CHECK_PRESENT => check_present,
            CHECK_PROTECTED => check_protected, CHECK_EXPIRED => check_expired,
            RING_REQUEST => open, RING_GRANT => '1', RING_DONE => open,
            RING_CONTINUE => open, RING_OWNER_ACTIVE => open,
            RB_RD_EN => rb_rd_en, RB_RD_CHUNK_ID => rb_rd_chunk_id,
            RB_RD_BATCH_IDX => rb_rd_batch_idx, RB_RD_DATA => rb_rd_data,
            RB_RD_VALID => rb_rd_valid, RB_RD_HIT => rb_rd_hit,
            EVENT_CREDIT => event_credit, EVENT_VALID => recorder_valid,
            EVENT_READY => recorder_ready, EVENT_DATA => recorder_data,
            EVENT_LAST => recorder_last, EVENT_CHUNK_ID => recorder_chunk_id,
            EVENT_TIMESTAMP => recorder_timestamp,
            EVENT_TRIGGER_OFFSET => recorder_offset, EVENT_SCORE => recorder_score,
            BUSY => open, EVENT_DONE_PULSE => open, EVENT_LOSS_PULSE => open,
            RING_MISS_COUNT => open
        );

    u_fifo : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK => clk, RST => rst,
            WR_VALID => recorder_valid, WR_READY => recorder_ready,
            WR_DATA => recorder_data, WR_LAST => recorder_last,
            WR_CHUNK_ID => recorder_chunk_id, WR_TIMESTAMP => recorder_timestamp,
            WR_TRIGGER_OFFSET => recorder_offset, WR_SCORE => recorder_score,
            EVENT_CREDIT => event_credit, FIFO_EMPTY => open,
            RD_VALID => event_valid, RD_READY => '1', RD_DATA => event_data,
            RD_LAST => event_last, RD_CHUNK_ID => event_chunk_id,
            RD_TIMESTAMP => event_timestamp, RD_TRIGGER_OFFSET => event_offset,
            RD_SCORE => event_score
        );

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';

        for chunk in 0 to 1 loop
            for beat in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, beat);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';

        for event_idx in 0 to EVENT_COUNT - 1 loop
            request_value.start_address.chunk_id <= to_unsigned(0, CHUNK_ID_WIDTH);
            request_value.start_address.beat_offset <= (others => '0');
            request_value.event_timestamp <= to_unsigned(event_idx, TIMESTAMP_WIDTH);
            request_value.trigger_offset <= (others => '0');
            request_value.score <= std_logic_vector(to_unsigned(event_idx, 32));
            request_valid <= '1';
            wait until rising_edge(clk);
            assert request_ready = '1'
                report "recorder backpressured a chunk-rate event request"
                severity failure;
            request_valid <= '0';

            -- Adjacent trigger chunks produce one request every 64 ADC beats.
            -- Keep that exact cadence instead of filling the recorder's
            -- pending slot early; this is the continuous-AI system boundary.
            if event_idx /= EVENT_COUNT - 1 then
                for cycle in 1 to N_BATCHES - 1 loop
                    wait until rising_edge(clk);
                end loop;
            end if;
        end loop;
        wait;
    end process;

    process
        variable seen           : integer := 0;
        variable stream_started : boolean := false;
        variable expected_event : integer;
        variable expected_beat  : integer;
    begin
        while seen < EVENT_COUNT * N_BATCHES loop
            wait until falling_edge(clk);
            if event_valid = '1' then
                stream_started := true;
                expected_event := seen / N_BATCHES;
                expected_beat  := seen mod N_BATCHES;
                assert event_timestamp = to_unsigned(expected_event, TIMESTAMP_WIDTH)
                    report "adjacent event metadata order mismatch" severity failure;
                assert to_integer(unsigned(event_data(11 downto 0))) = expected_beat
                    report "adjacent event waveform order mismatch" severity failure;
                if expected_beat = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "adjacent event final beat did not assert LAST"
                        severity failure;
                else
                    assert event_last = '0'
                        report "adjacent event asserted LAST early"
                        severity failure;
                end if;
                seen := seen + 1;
            elsif stream_started then
                assert false
                    report "adjacent recorder events inserted an output bubble after beat " &
                           integer'image(seen)
                    severity failure;
            end if;
        end loop;

        report "tb_event_recorder_adjacent_events passed";
        stop;
        wait;
    end process;

end architecture sim;
