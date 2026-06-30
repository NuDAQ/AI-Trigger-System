library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_trigger_cdc_fifo is
end entity tb_trigger_cdc_fifo;

architecture sim of tb_trigger_cdc_fifo is
    signal wr_clk       : std_logic := '0';
    signal rd_clk       : std_logic := '0';
    signal wr_rst       : std_logic := '1';
    signal rd_rst       : std_logic := '1';
    signal wr_valid     : std_logic := '0';
    signal wr_ready     : std_logic;
    signal wr_chunk_id  : chunk_id_t := (others => '0');
    signal wr_score     : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_timestamp : timestamp_t := (others => '0');
    signal rd_valid     : std_logic;
    signal rd_ready     : std_logic := '0';
    signal rd_chunk_id  : chunk_id_t;
    signal rd_score     : std_logic_vector(31 downto 0);
    signal rd_timestamp : timestamp_t;
begin
    wr_clk <= not wr_clk after 3 ns;
    rd_clk <= not rd_clk after 5 ns;

    u_dut : entity work.TRIGGER_CDC_FIFO
        port map (
            WR_CLK       => wr_clk,
            WR_RST       => wr_rst,
            WR_VALID     => wr_valid,
            WR_READY     => wr_ready,
            WR_CHUNK_ID  => wr_chunk_id,
            WR_SCORE     => wr_score,
            WR_TIMESTAMP => wr_timestamp,
            RD_CLK       => rd_clk,
            RD_RST       => rd_rst,
            RD_VALID     => rd_valid,
            RD_READY     => rd_ready,
            RD_CHUNK_ID  => rd_chunk_id,
            RD_SCORE     => rd_score,
            RD_TIMESTAMP => rd_timestamp
        );

    process
    begin
        wait until rising_edge(wr_clk);
        wr_rst <= '0';
        wait;
    end process;

    process
    begin
        wait until rising_edge(rd_clk);
        rd_rst <= '0';
        wait;
    end process;

    process
    begin
        wait until wr_rst = '0';
        wait until rising_edge(wr_clk);

        for i in 0 to 4 loop
            wr_valid    <= '1';
            wr_chunk_id <= to_unsigned(20 + i, CHUNK_ID_WIDTH);
            wr_score    <= std_logic_vector(to_signed(1000 + i, 32));
            wr_timestamp <= to_unsigned(120 + i, TIMESTAMP_WIDTH);
            wait until rising_edge(wr_clk);
            assert wr_ready = '1'
                report "trigger fifo unexpectedly full"
                severity failure;
        end loop;
        wr_valid <= '0';
        wait;
    end process;

    process
    begin
        wait until rd_rst = '0';
        repeat_wait : for i in 0 to 5 loop
            wait until rising_edge(rd_clk);
        end loop;

        for i in 0 to 4 loop
            wait until rising_edge(rd_clk) and rd_valid = '1';
            wait for 1 ns;
            assert rd_chunk_id = to_unsigned(20 + i, CHUNK_ID_WIDTH)
                report "trigger fifo chunk id order mismatch"
                severity failure;
            assert rd_score = std_logic_vector(to_signed(1000 + i, 32))
                report "trigger fifo score order mismatch"
                severity failure;
            assert rd_timestamp = to_unsigned(120 + i, TIMESTAMP_WIDTH)
                report "trigger fifo timestamp order mismatch"
                severity failure;
            rd_ready <= '1';
            wait until rising_edge(rd_clk);
            rd_ready <= '0';
        end loop;

        report "tb_trigger_cdc_fifo passed";
        stop;
    end process;
end architecture sim;
