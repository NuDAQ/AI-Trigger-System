library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_output_fifo_throughput is
end entity tb_event_output_fifo_throughput;

architecture sim of tb_event_output_fifo_throughput is
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
        variable ret : raw_adc_batch_t := (others => '0');
    begin
        ret(15 downto 0) := std_logic_vector(to_unsigned(i, 16));
        return ret;
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
            WR_SCORE     => wr_score,
            RD_VALID     => rd_valid,
            RD_READY     => rd_ready,
            RD_DATA      => rd_data,
            RD_LAST      => rd_last,
            RD_CHUNK_ID  => rd_chunk_id,
            RD_TIMESTAMP => rd_timestamp,
            RD_SCORE     => rd_score
        );

    process
        variable seen : integer := 0;
        variable cycles_with_data : integer := 0;
    begin
        wait until rising_edge(clk);
        rst <= '0';

        for i in 0 to 7 loop
            wr_valid     <= '1';
            wr_data      <= word_for(i);
            wr_last      <= '1' when i = 7 else '0';
            wr_chunk_id  <= to_unsigned(100 + i, CHUNK_ID_WIDTH);
            wr_timestamp <= to_unsigned(200 + i, TIMESTAMP_WIDTH);
            wr_score     <= std_logic_vector(to_unsigned(300 + i, 32));
            wait until rising_edge(clk);
            assert wr_ready = '1'
                report "event output FIFO unexpectedly backpressured during short burst"
                severity failure;
        end loop;
        wr_valid <= '0';
        wr_last  <= '0';

        rd_ready <= '1';
        while rd_valid /= '1' loop
            wait until rising_edge(clk);
        end loop;
        while seen < 8 loop
            wait until falling_edge(clk);
            assert rd_valid = '1'
                report "event output FIFO inserted a bubble while downstream was ready"
                severity failure;
            assert rd_data = word_for(seen)
                report "event output FIFO data order mismatch seen=" &
                       integer'image(seen) &
                       " got=" & integer'image(to_integer(unsigned(rd_data(15 downto 0)))) &
                       " expected=" & integer'image(seen)
                severity failure;
            assert rd_chunk_id = to_unsigned(100 + seen, CHUNK_ID_WIDTH)
                report "event output FIFO chunk id order mismatch"
                severity failure;
            assert rd_timestamp = to_unsigned(200 + seen, TIMESTAMP_WIDTH)
                report "event output FIFO timestamp order mismatch"
                severity failure;
            assert rd_score = std_logic_vector(to_unsigned(300 + seen, 32))
                report "event output FIFO score order mismatch"
                severity failure;
            if seen = 7 then
                assert rd_last = '1'
                    report "event output FIFO final beat must preserve LAST"
                    severity failure;
            else
                assert rd_last = '0'
                    report "event output FIFO non-final beat must not assert LAST"
                    severity failure;
            end if;
            seen := seen + 1;
            cycles_with_data := cycles_with_data + 1;
            wait until rising_edge(clk);
        end loop;

        assert cycles_with_data = 8
            report "event output FIFO did not produce the complete burst"
            severity failure;

        report "tb_event_output_fifo_throughput passed";
        stop;
    end process;
end architecture sim;
