library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_recorder_centered is
end entity tb_event_recorder_centered;

architecture sim of tb_event_recorder_centered is
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal data_str             : std_logic := '0';
    signal adc_data4            : adc_data4_t;
    signal chunk_commit         : std_logic;
    signal commit_chunk_id      : chunk_id_t;
    signal request_valid        : std_logic := '0';
    signal request_ready        : std_logic;
    signal request_value        : event_request_t;
    signal check_start_chunk_id : chunk_id_t;
    signal check_start_offset   : beat_offset_t;
    signal check_present        : std_logic;
    signal check_protected      : std_logic;
    signal check_expired        : std_logic;
    signal recorder_check_valid : std_logic;
    signal recorder_ring_request : std_logic;
    signal recorder_ring_done    : std_logic;
    signal recorder_ring_continue : std_logic;
    signal recorder_owner_active : std_logic;
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
    signal fifo_empty           : std_logic;
    signal event_valid          : std_logic;
    signal event_data           : raw_adc_batch_t;
    signal event_last           : std_logic;
    signal event_chunk_id       : chunk_id_t;
    signal event_timestamp      : timestamp_t;
    signal event_offset         : beat_offset_t;
    signal event_score          : std_logic_vector(31 downto 0);
    signal recorder_busy        : std_logic;
    signal recorder_done_pulse  : std_logic;
    signal recorder_done_seen   : std_logic := '0';
    signal event_loss_pulse     : std_logic;
    signal ring_miss_count      : unsigned(31 downto 0);

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (chunk_value * 64 + beat_value + ch * 256) mod 4096, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_ring : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK                  => clk,
            RST                  => rst,
            DATA_STR             => data_str,
            ADC_DATA4            => adc_data4,
            CHUNK_COMMIT         => chunk_commit,
            COMMIT_CHUNK_ID      => commit_chunk_id,
            COMMIT_TIMESTAMP     => open,
            WRITE_CHUNK_ID       => open,
            WRITE_BEAT_OFFSET    => open,
            WRITE_TIMESTAMP      => open,
            CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET   => check_start_offset,
            CHECK_PRESENT        => check_present,
            CHECK_PROTECTED      => check_protected,
            CHECK_EXPIRED        => check_expired,
            RD_EN                => rb_rd_en,
            RD_CHUNK_ID          => rb_rd_chunk_id,
            RD_BATCH_IDX         => rb_rd_batch_idx,
            RD_DATA              => rb_rd_data,
            RD_VALID             => rb_rd_valid,
            RD_HIT               => rb_rd_hit
        );

    u_recorder : entity work.EVENT_RECORDER
        port map (
            CLK                  => clk,
            RST                  => rst,
            REQUEST_VALID        => request_valid,
            REQUEST_READY        => request_ready,
            REQUEST_VALUE        => request_value,
            CHECK_VALID          => recorder_check_valid,
            CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET   => check_start_offset,
            CHECK_PRESENT        => check_present,
            CHECK_PROTECTED      => check_protected,
            CHECK_EXPIRED        => check_expired,
            RING_REQUEST          => recorder_ring_request,
            RING_GRANT            => '1',
            RING_DONE             => recorder_ring_done,
            RING_CONTINUE         => recorder_ring_continue,
            RING_OWNER_ACTIVE     => recorder_owner_active,
            RB_RD_EN             => rb_rd_en,
            RB_RD_CHUNK_ID       => rb_rd_chunk_id,
            RB_RD_BATCH_IDX      => rb_rd_batch_idx,
            RB_RD_DATA           => rb_rd_data,
            RB_RD_VALID          => rb_rd_valid,
            RB_RD_HIT            => rb_rd_hit,
            EVENT_CREDIT         => event_credit,
            EVENT_VALID          => recorder_valid,
            EVENT_READY          => recorder_ready,
            EVENT_DATA           => recorder_data,
            EVENT_LAST           => recorder_last,
            EVENT_CHUNK_ID       => recorder_chunk_id,
            EVENT_TIMESTAMP      => recorder_timestamp,
            EVENT_TRIGGER_OFFSET => recorder_offset,
            EVENT_SCORE          => recorder_score,
            BUSY                 => recorder_busy,
            EVENT_DONE_PULSE     => recorder_done_pulse,
            EVENT_LOSS_PULSE     => event_loss_pulse,
            RING_MISS_COUNT      => ring_miss_count
        );

    u_fifo : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK               => clk,
            RST               => rst,
            WR_VALID          => recorder_valid,
            WR_READY          => recorder_ready,
            WR_DATA           => recorder_data,
            WR_LAST           => recorder_last,
            WR_CHUNK_ID       => recorder_chunk_id,
            WR_TIMESTAMP      => recorder_timestamp,
            WR_TRIGGER_OFFSET => recorder_offset,
            WR_SCORE          => recorder_score,
            EVENT_CREDIT      => event_credit,
            FIFO_EMPTY        => fifo_empty,
            RD_VALID          => event_valid,
            RD_READY          => '1',
            RD_DATA           => event_data,
            RD_LAST           => event_last,
            RD_CHUNK_ID       => event_chunk_id,
            RD_TIMESTAMP      => event_timestamp,
            RD_TRIGGER_OFFSET => event_offset,
            RD_SCORE          => event_score
        );

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                recorder_done_seen <= '0';
            elsif recorder_done_pulse = '1' then
                recorder_done_seen <= '1';
            end if;
        end if;
    end process;

    process
        variable seen           : integer := 0;
        variable stream_started : boolean := false;
        variable expected       : integer;
    begin
        request_value.start_address.chunk_id    <= (others => '0');
        request_value.start_address.beat_offset <= to_unsigned(40, BEAT_OFFSET_WIDTH);
        request_value.event_timestamp           <= to_unsigned(1, TIMESTAMP_WIDTH);
        request_value.trigger_offset            <= to_unsigned(10, BEAT_OFFSET_WIDTH);
        request_value.score                     <= x"12345678";

        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(sample_idx) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst <= '0';
        for chunk_value in 0 to 1 loop
            for beat_value in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, chunk_value, beat_value);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';

        request_valid <= '1';
        loop
            wait until rising_edge(clk);
            exit when request_ready = '1';
        end loop;
        request_valid <= '0';

        while seen < N_BATCHES loop
            wait until falling_edge(clk);
            if event_valid = '1' then
                stream_started := true;
                expected := 40 + seen;
                assert to_integer(unsigned(event_data(11 downto 0))) = expected
                    report "centered event data order mismatch" severity failure;
                assert to_integer(unsigned(event_data(
                    (7 * N_BATCH_S) * 12 + 11 downto
                    (7 * N_BATCH_S) * 12))) = (expected + 7 * 256) mod 4096
                    report "recording path must retain channel 7" severity failure;
                assert event_timestamp = to_unsigned(1, TIMESTAMP_WIDTH) and
                       event_offset = to_unsigned(10, BEAT_OFFSET_WIDTH) and
                       event_score = x"12345678"
                    report "event request metadata changed during recording" severity failure;
                if seen = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "centered event final beat must assert LAST" severity failure;
                else
                    assert event_last = '0'
                        report "centered event asserted LAST early" severity failure;
                end if;
                seen := seen + 1;
            elsif stream_started then
                assert false
                    report "centered event output inserted a bubble" severity failure;
            end if;
        end loop;

        assert ring_miss_count = 0 and event_loss_pulse = '0'
            report "a protected centered event must not report loss" severity failure;
        assert recorder_done_seen = '1'
            report "recorder must pulse done when the final beat enters the FIFO" severity failure;
        report "tb_event_recorder_centered passed";
        stop;
        wait;
    end process;
end architecture sim;
