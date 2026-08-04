library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_output_fifo_adjacent_events is
end entity tb_event_output_fifo_adjacent_events;

architecture sim of tb_event_output_fifo_adjacent_events is
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal wr_valid     : std_logic := '0';
    signal wr_ready     : std_logic;
    signal wr_data      : raw_adc_batch_t := (others => '0');
    signal wr_last      : std_logic := '0';
    signal wr_chunk_id  : chunk_id_t := (others => '0');
    signal wr_timestamp : timestamp_t := (others => '0');
    signal wr_score     : std_logic_vector(31 downto 0) := (others => '0');
    signal rd_valid     : std_logic;
    signal rd_ready     : std_logic := '0';
    signal rd_data      : raw_adc_batch_t;
    signal rd_last      : std_logic;
    signal rd_chunk_id  : chunk_id_t;
    signal rd_timestamp : timestamp_t;
    signal rd_score     : std_logic_vector(31 downto 0);

    function word_for(i : integer) return raw_adc_batch_t is
        variable result : raw_adc_batch_t := (others => '0');
    begin
        result(15 downto 0) := std_logic_vector(to_unsigned(i, 16));
        return result;
    end function;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK          => clk,
            RST          => rst,
            WR_VALID     => wr_valid,
            WR_READY     => wr_ready,
            WR_DATA      => wr_data,
            WR_LAST      => wr_last,
            WR_CHUNK_ID  => wr_chunk_id,
            WR_TIMESTAMP => wr_timestamp,
            WR_TRIGGER_OFFSET => (others => '0'),
            WR_SCORE     => wr_score,
            EVENT_CREDIT => open,
            FIFO_EMPTY   => open,
            RD_VALID     => rd_valid,
            RD_READY     => rd_ready,
            RD_DATA      => rd_data,
            RD_LAST      => rd_last,
            RD_CHUNK_ID  => rd_chunk_id,
            RD_TIMESTAMP => rd_timestamp,
            RD_TRIGGER_OFFSET => open,
            RD_SCORE     => rd_score
        );

    process
    begin
        wait until rising_edge(clk);
        rst      <= '0';
        rd_ready <= '1';

        -- First complete 64-beat event.
        for beat in 0 to N_BATCHES - 1 loop
            wr_valid     <= '1';
            wr_data      <= word_for(beat);
            wr_last      <= '1' when beat = N_BATCHES - 1 else '0';
            wr_chunk_id  <= to_unsigned(10, CHUNK_ID_WIDTH);
            wr_timestamp <= to_unsigned(100, TIMESTAMP_WIDTH);
            wr_score     <= std_logic_vector(to_signed(1000, 32));
            wait until rising_edge(clk);
            assert wr_ready = '1'
                report "adjacent-event FIFO backpressured the first event"
                severity failure;
        end loop;

        -- Model the observed 260 ns trigger spacing: one idle 4 ns ADC cycle
        -- between two otherwise line-rate 64-beat event writes.
        wr_valid <= '0';
        wr_last  <= '0';
        wait until rising_edge(clk);

        for beat in 0 to N_BATCHES - 1 loop
            wr_valid     <= '1';
            wr_data      <= word_for(N_BATCHES + beat);
            wr_last      <= '1' when beat = N_BATCHES - 1 else '0';
            wr_chunk_id  <= to_unsigned(11, CHUNK_ID_WIDTH);
            wr_timestamp <= to_unsigned(101, TIMESTAMP_WIDTH);
            wr_score     <= std_logic_vector(to_signed(1001, 32));
            wait until rising_edge(clk);
            assert wr_ready = '1'
                report "adjacent-event FIFO backpressured the second event"
                severity failure;
        end loop;
        wr_valid <= '0';
        wr_last  <= '0';
        wait;
    end process;

    process
        variable seen           : integer := 0;
        variable stream_started : boolean := false;
        variable expected_chunk : integer;
    begin
        while seen < 2 * N_BATCHES loop
            wait until falling_edge(clk);
            if rd_valid = '1' then
                stream_started := true;
                if seen < N_BATCHES then
                    expected_chunk := 10;
                else
                    expected_chunk := 11;
                end if;

                assert rd_data = word_for(seen)
                    report "adjacent-event FIFO data order mismatch at beat " &
                           integer'image(seen)
                    severity failure;
                assert rd_chunk_id = to_unsigned(expected_chunk, CHUNK_ID_WIDTH)
                    report "adjacent-event FIFO chunk id mismatch at beat " &
                           integer'image(seen)
                    severity failure;
                if seen = N_BATCHES - 1 or seen = 2 * N_BATCHES - 1 then
                    assert rd_last = '1'
                        report "adjacent-event FIFO final beat must assert LAST"
                        severity failure;
                else
                    assert rd_last = '0'
                        report "adjacent-event FIFO non-final beat asserted LAST"
                        severity failure;
                end if;
                seen := seen + 1;
            elsif stream_started then
                assert false
                    report "adjacent events contained an output bubble while RD_READY was high"
                    severity failure;
            end if;
        end loop;

        report "tb_event_output_fifo_adjacent_events passed";
        stop;
    end process;
end architecture sim;
