library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_capture_ctrl_late_trigger is
end entity tb_event_capture_ctrl_late_trigger;

architecture sim of tb_event_capture_ctrl_late_trigger is
    signal clk               : std_logic := '0';
    signal rst               : std_logic := '1';
    signal chunk_commit      : std_logic := '0';
    signal commit_chunk_id   : chunk_id_t := (others => '0');
    signal trigger_valid     : std_logic := '0';
    signal trigger_ready     : std_logic;
    signal trigger_chunk_id  : chunk_id_t := (others => '0');
    signal trigger_score     : std_logic_vector(31 downto 0) := (others => '0');
    signal trigger_timestamp : timestamp_t := (others => '0');
    signal rb_rd_en          : std_logic;
    signal rb_rd_chunk_id    : chunk_id_t;
    signal rb_rd_batch_idx   : integer range 0 to N_BATCHES - 1;
    signal rb_rd_data        : raw_adc_batch_t := (others => '0');
    signal rb_rd_valid       : std_logic := '0';
    signal rb_rd_hit         : std_logic := '0';
    signal event_valid       : std_logic;
    signal event_ready       : std_logic := '1';
    signal event_data        : raw_adc_batch_t;
    signal event_last        : std_logic;
    signal event_chunk_id    : chunk_id_t;
    signal event_timestamp   : timestamp_t;
    signal event_score       : std_logic_vector(31 downto 0);
    signal ring_miss_count   : unsigned(31 downto 0);

    function response_word(chunk_id : chunk_id_t; batch_idx : integer)
        return raw_adc_batch_t is
        variable result : raw_adc_batch_t := (others => '0');
    begin
        result(15 downto 0) := std_logic_vector(chunk_id);
        result(31 downto 16) := std_logic_vector(to_unsigned(batch_idx, 16));
        return result;
    end function;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.EVENT_CAPTURE_CTRL
        port map (
            CLK               => clk,
            RST               => rst,
            CHUNK_COMMIT      => chunk_commit,
            COMMIT_CHUNK_ID   => commit_chunk_id,
            TRIGGER_VALID     => trigger_valid,
            TRIGGER_READY     => trigger_ready,
            TRIGGER_CHUNK_ID  => trigger_chunk_id,
            TRIGGER_SCORE     => trigger_score,
            TRIGGER_TIMESTAMP => trigger_timestamp,
            RB_RD_EN          => rb_rd_en,
            RB_RD_CHUNK_ID    => rb_rd_chunk_id,
            RB_RD_BATCH_IDX   => rb_rd_batch_idx,
            RB_RD_DATA        => rb_rd_data,
            RB_RD_VALID       => rb_rd_valid,
            RB_RD_HIT         => rb_rd_hit,
            EVENT_VALID       => event_valid,
            EVENT_READY       => event_ready,
            EVENT_DATA        => event_data,
            EVENT_LAST        => event_last,
            EVENT_CHUNK_ID    => event_chunk_id,
            EVENT_TIMESTAMP   => event_timestamp,
            EVENT_SCORE       => event_score,
            RING_MISS_COUNT   => ring_miss_count
        );

    -- Match the ring buffer's registered, one-cycle read response.
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rb_rd_valid <= '0';
                rb_rd_hit   <= '0';
                rb_rd_data  <= (others => '0');
            else
                rb_rd_valid <= rb_rd_en;
                rb_rd_hit   <= rb_rd_en;
                if rb_rd_en = '1' then
                    rb_rd_data <= response_word(rb_rd_chunk_id, rb_rd_batch_idx);
                end if;
            end if;
        end if;
    end process;

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';

        -- Both consecutive chunks are already available in the ring.
        commit_chunk_id <= to_unsigned(1, CHUNK_ID_WIDTH);
        chunk_commit    <= '1';
        wait until rising_edge(clk);
        chunk_commit <= '0';

        trigger_chunk_id  <= to_unsigned(0, CHUNK_ID_WIDTH);
        trigger_timestamp <= to_unsigned(100, TIMESTAMP_WIDTH);
        trigger_score     <= std_logic_vector(to_signed(2000, 32));
        trigger_valid     <= '1';
        wait until rising_edge(clk);
        trigger_valid <= '0';

        -- Present the next trigger after the first event's final request has
        -- already been issued. The controller must launch its first read
        -- immediately to keep the ring-read pipeline continuous.
        wait until rb_rd_en = '1' and rb_rd_batch_idx = N_BATCHES - 1;
        trigger_chunk_id  <= to_unsigned(1, CHUNK_ID_WIDTH);
        trigger_timestamp <= to_unsigned(101, TIMESTAMP_WIDTH);
        trigger_score     <= std_logic_vector(to_signed(2001, 32));
        trigger_valid     <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert trigger_ready = '1'
            report "late consecutive trigger was not accepted"
            severity failure;
        assert rb_rd_en = '1' and rb_rd_batch_idx = 0 and
               rb_rd_chunk_id = to_unsigned(1, CHUNK_ID_WIDTH)
            report "late consecutive trigger inserted a ring-read request bubble"
            severity failure;
        trigger_valid <= '0';

        wait;
    end process;

    process
        variable seen           : integer := 0;
        variable stream_started : boolean := false;
        variable expected_chunk : integer;
        variable expected_batch : integer;
    begin
        while seen < 2 * N_BATCHES loop
            wait until rising_edge(clk);
            wait for 1 ns;
            if event_valid = '1' then
                stream_started := true;
                expected_chunk := seen / N_BATCHES;
                expected_batch := seen mod N_BATCHES;
                assert event_chunk_id = to_unsigned(expected_chunk, CHUNK_ID_WIDTH)
                    report "late-trigger event chunk id mismatch"
                    severity failure;
                assert unsigned(event_data(15 downto 0)) =
                       to_unsigned(expected_chunk, 16)
                    report "late-trigger event data chunk mismatch"
                    severity failure;
                assert unsigned(event_data(31 downto 16)) =
                       to_unsigned(expected_batch, 16)
                    report "late-trigger event data batch mismatch"
                    severity failure;
                if expected_batch = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "late-trigger final beat must assert LAST"
                        severity failure;
                else
                    assert event_last = '0'
                        report "late-trigger non-final beat asserted LAST"
                        severity failure;
                end if;
                seen := seen + 1;
            elsif stream_started then
                assert false
                    report "late consecutive trigger inserted an event output bubble"
                    severity failure;
            end if;
        end loop;

        assert ring_miss_count = to_unsigned(0, ring_miss_count'length)
            report "late consecutive trigger caused a ring miss"
            severity failure;
        report "tb_event_capture_ctrl_late_trigger passed";
        stop;
    end process;
end architecture sim;
