library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_output_fifo_credit is
end entity tb_event_output_fifo_credit;

architecture sim of tb_event_output_fifo_credit is
    signal clk               : std_logic := '0';
    signal rst               : std_logic := '1';
    signal wr_valid          : std_logic := '0';
    signal wr_ready          : std_logic;
    signal wr_data           : raw_adc_batch_t := (others => '0');
    signal wr_last           : std_logic := '0';
    signal wr_chunk_id       : chunk_id_t := (others => '0');
    signal wr_timestamp      : timestamp_t := (others => '0');
    signal wr_trigger_offset : beat_offset_t := (others => '0');
    signal wr_score          : std_logic_vector(31 downto 0) := (others => '0');
    signal event_credit      : std_logic;
    signal fifo_empty        : std_logic;
    signal rd_valid          : std_logic;
    signal rd_ready          : std_logic := '0';
    signal rd_data           : raw_adc_batch_t;
    signal rd_last           : std_logic;
    signal rd_chunk_id       : chunk_id_t;
    signal rd_timestamp      : timestamp_t;
    signal rd_trigger_offset : beat_offset_t;
    signal rd_score          : std_logic_vector(31 downto 0);
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK               => clk,
            RST               => rst,
            WR_VALID          => wr_valid,
            WR_READY          => wr_ready,
            WR_DATA           => wr_data,
            WR_LAST           => wr_last,
            WR_CHUNK_ID       => wr_chunk_id,
            WR_TIMESTAMP      => wr_timestamp,
            WR_TRIGGER_OFFSET => wr_trigger_offset,
            WR_SCORE          => wr_score,
            EVENT_CREDIT      => event_credit,
            FIFO_EMPTY        => fifo_empty,
            RD_VALID          => rd_valid,
            RD_READY          => rd_ready,
            RD_DATA           => rd_data,
            RD_LAST           => rd_last,
            RD_CHUNK_ID       => rd_chunk_id,
            RD_TIMESTAMP      => rd_timestamp,
            RD_TRIGGER_OFFSET => rd_trigger_offset,
            RD_SCORE          => rd_score
        );

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert event_credit = '1' and fifo_empty = '1'
            report "an empty FIFO must have one-event credit and report empty" severity failure;

        for beat in 0 to N_BATCHES - 1 loop
            wr_valid <= '1';
            wr_data(15 downto 0) <= std_logic_vector(to_unsigned(beat, 16));
            wait until rising_edge(clk);
        end loop;
        wait for 1 ps;
        assert event_credit = '1'
            report "exactly 64 free entries must retain one-event credit" severity failure;

        wait until rising_edge(clk);
        wait for 1 ps;
        assert event_credit = '0'
            report "fewer than 64 free entries must remove event credit" severity failure;

        wr_valid <= '0';
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        for beat in 0 to 2 loop
            wr_valid          <= '1';
            wr_last           <= '1' when beat = 2 else '0';
            wr_trigger_offset <= to_unsigned(17, BEAT_OFFSET_WIDTH);
            wait until rising_edge(clk);
        end loop;
        wr_valid <= '0';
        wr_last  <= '0';

        while rd_valid = '0' loop
            wait until rising_edge(clk);
        end loop;
        wait for 1 ps;
        assert fifo_empty = '0'
            report "a held output word means the event FIFO is not drained" severity failure;
        assert rd_trigger_offset = to_unsigned(17, BEAT_OFFSET_WIDTH)
            report "trigger offset metadata was not preserved" severity failure;

        rd_ready <= '1';
        while fifo_empty = '0' loop
            wait until rising_edge(clk);
            wait for 1 ps;
        end loop;

        report "tb_event_output_fifo_credit passed";
        stop;
        wait;
    end process;
end architecture sim;
