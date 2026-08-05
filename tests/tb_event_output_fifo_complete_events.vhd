library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_output_fifo_complete_events is
end entity tb_event_output_fifo_complete_events;

architecture sim of tb_event_output_fifo_complete_events is
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal wr_valid     : std_logic := '0';
    signal wr_ready     : std_logic;
    signal wr_data      : raw_adc_batch_t := (others => '0');
    signal wr_last      : std_logic := '0';
    signal wr_chunk_id  : chunk_id_t := (others => '0');
    signal rd_valid     : std_logic;
    signal rd_data      : raw_adc_batch_t;
    signal rd_last      : std_logic;
    signal rd_chunk_id  : chunk_id_t;

    function word_for(event_idx : integer; beat : integer)
        return raw_adc_batch_t is
        variable result : raw_adc_batch_t := (others => '0');
    begin
        result(15 downto 0) := std_logic_vector(to_unsigned(
            event_idx * N_BATCHES + beat, 16));
        return result;
    end function;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK => clk, RST => rst,
            WR_VALID => wr_valid, WR_READY => wr_ready,
            WR_DATA => wr_data, WR_LAST => wr_last,
            WR_CHUNK_ID => wr_chunk_id, WR_TIMESTAMP => (others => '0'),
            WR_TRIGGER_OFFSET => (others => '0'), WR_SCORE => (others => '0'),
            EVENT_CREDIT => open, FIFO_EMPTY => open,
            RD_VALID => rd_valid, RD_READY => '1', RD_DATA => rd_data,
            RD_LAST => rd_last, RD_CHUNK_ID => rd_chunk_id,
            RD_TIMESTAMP => open, RD_TRIGGER_OFFSET => open, RD_SCORE => open
        );

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';

        for beat in 0 to N_BATCHES - 1 loop
            wr_valid <= '1';
            wr_data <= word_for(0, beat);
            wr_last <= '1' when beat = N_BATCHES - 1 else '0';
            wr_chunk_id <= to_unsigned(10, CHUNK_ID_WIDTH);
            wait until rising_edge(clk);
            assert wr_ready = '1' severity failure;
        end loop;

        -- The second event is intentionally incomplete while the first event
        -- drains.  No beat of it may escape until its LAST beat commits the
        -- complete event to the public output stream.
        for beat in 0 to N_BATCHES - 1 loop
            wr_valid <= '1';
            wr_data <= word_for(1, beat);
            wr_last <= '1' when beat = N_BATCHES - 1 else '0';
            wr_chunk_id <= to_unsigned(11, CHUNK_ID_WIDTH);
            wait until rising_edge(clk);
            assert wr_ready = '1' severity failure;
            wr_valid <= '0';
            wr_last <= '0';
            wait until rising_edge(clk);
        end loop;
        wr_valid <= '0';
        wr_last <= '0';
        wait;
    end process;

    process
        variable event_idx      : integer := 0;
        variable beat_idx       : integer := 0;
        variable event_started  : boolean := false;
    begin
        while event_idx < 2 loop
            wait until falling_edge(clk);
            if rd_valid = '1' then
                event_started := true;
                assert rd_chunk_id = to_unsigned(10 + event_idx, CHUNK_ID_WIDTH)
                    report "complete-event FIFO chunk order mismatch"
                    severity failure;
                assert rd_data = word_for(event_idx, beat_idx)
                    report "complete-event FIFO payload order mismatch"
                    severity failure;
                if beat_idx = N_BATCHES - 1 then
                    assert rd_last = '1'
                        report "complete-event FIFO final beat did not assert LAST"
                        severity failure;
                    event_idx := event_idx + 1;
                    beat_idx := 0;
                    event_started := false;
                else
                    assert rd_last = '0'
                        report "complete-event FIFO asserted LAST early"
                        severity failure;
                    beat_idx := beat_idx + 1;
                end if;
            elsif event_started then
                assert false
                    report "FIFO exposed an incomplete event and inserted a payload bubble"
                    severity failure;
            end if;
        end loop;

        report "tb_event_output_fifo_complete_events passed";
        stop;
        wait;
    end process;
end architecture sim;
