library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_trigger_decision is
end entity tb_trigger_decision;

architecture sim of tb_trigger_decision is
    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal score_valid      : std_logic := '0';
    signal score_data       : std_logic_vector(31 downto 0) := (others => '0');
    signal score_chunk_id   : chunk_id_t := (others => '0');
    signal score_timestamp  : timestamp_t := (others => '0');
    signal cnn_thresh       : std_logic_vector(31 downto 0) := (others => '0');
    signal trigger_valid    : std_logic;
    signal trigger_score    : std_logic_vector(31 downto 0);
    signal trigger_chunk_id : chunk_id_t;
    signal trigger_timestamp : timestamp_t;
begin
    clk <= not clk after 5 ns;

    u_dut : entity work.TRIGGER_DECISION
        port map (
            CLK              => clk,
            RST              => rst,
            SCORE_VALID      => score_valid,
            SCORE_DATA       => score_data,
            SCORE_CHUNK_ID   => score_chunk_id,
            SCORE_TIMESTAMP  => score_timestamp,
            CNN_THRESH       => cnn_thresh,
            TRIGGER_VALID    => trigger_valid,
            TRIGGER_SCORE    => trigger_score,
            TRIGGER_CHUNK_ID => trigger_chunk_id,
            TRIGGER_TIMESTAMP => trigger_timestamp
        );

    process
    begin
        cnn_thresh <= std_logic_vector(to_signed(1024, 32));

        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        score_valid    <= '1';
        score_data     <= std_logic_vector(to_signed(512, 32));
        score_chunk_id <= to_unsigned(7, CHUNK_ID_WIDTH);
        score_timestamp <= to_unsigned(107, TIMESTAMP_WIDTH);
        wait until rising_edge(clk);
        score_valid <= '0';
        wait until rising_edge(clk);
        assert trigger_valid = '0'
            report "score below threshold must be discarded"
            severity failure;

        score_valid    <= '1';
        score_data     <= std_logic_vector(to_signed(2048, 32));
        score_chunk_id <= to_unsigned(8, CHUNK_ID_WIDTH);
        score_timestamp <= to_unsigned(108, TIMESTAMP_WIDTH);
        wait until rising_edge(clk);
        score_valid <= '0';
        wait until rising_edge(clk);
        assert trigger_valid = '1'
            report "score above threshold must raise trigger_valid"
            severity failure;
        assert trigger_score = std_logic_vector(to_signed(2048, 32))
            report "trigger must preserve the score"
            severity failure;
        assert trigger_chunk_id = to_unsigned(8, CHUNK_ID_WIDTH)
            report "trigger must preserve the chunk id"
            severity failure;
        assert trigger_timestamp = to_unsigned(108, TIMESTAMP_WIDTH)
            report "trigger must preserve the timestamp"
            severity failure;

        wait until rising_edge(clk);
        assert trigger_valid = '0'
            report "trigger_valid must be a one-cycle pulse"
            severity failure;

        report "tb_trigger_decision passed";
        stop;
    end process;
end architecture sim;
