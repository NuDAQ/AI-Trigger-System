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

    procedure enqueue_trigger(
        signal valid     : out std_logic;
        signal chunk_id  : out chunk_id_t;
        signal score     : out std_logic_vector(31 downto 0);
        signal timestamp : out timestamp_t;
        constant id      : in integer;
        constant score_i : in integer;
        constant ts      : in integer
    ) is
    begin
        valid     <= '1';
        chunk_id  <= to_unsigned(id, CHUNK_ID_WIDTH);
        score     <= std_logic_vector(to_signed(score_i, 32));
        timestamp <= to_unsigned(ts, TIMESTAMP_WIDTH);
        wait until rising_edge(wr_clk);
        valid <= '0';
    end procedure;

    procedure wait_for_read_valid(
        signal valid : in std_logic;
        constant max_cycles : in integer
    ) is
    begin
        for i in 0 to max_cycles - 1 loop
            wait until rising_edge(rd_clk);
            if valid = '1' then
                return;
            end if;
        end loop;
        assert false
            report "timed out waiting for trigger fifo read descriptor"
            severity failure;
    end procedure;
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
            enqueue_trigger(
                wr_valid,
                wr_chunk_id,
                wr_score,
                wr_timestamp,
                20 + i,
                1000 + i,
                120 + i
            );
            assert wr_ready = '1'
                report "trigger fifo unexpectedly full"
                severity failure;
        end loop;

        for i in 0 to 12 loop
            wait until rising_edge(wr_clk);
        end loop;

        enqueue_trigger(
            wr_valid,
            wr_chunk_id,
            wr_score,
            wr_timestamp,
            99,
            1999,
            199
        );
        wait;
    end process;

    process
    begin
        wait until rd_rst = '0';
        repeat_wait : for i in 0 to 5 loop
            wait until rising_edge(rd_clk);
        end loop;

        for i in 0 to 4 loop
            wait_for_read_valid(rd_valid, 80);
            wait for 1 ns;
            assert rd_chunk_id = to_unsigned(20 + i, CHUNK_ID_WIDTH)
                report "trigger fifo chunk id order mismatch: expected "
                    & integer'image(20 + i)
                    & " got "
                    & integer'image(to_integer(rd_chunk_id))
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

        for i in 0 to 20 loop
            wait until rising_edge(rd_clk);
            assert rd_valid = '0' or rd_chunk_id /= to_unsigned(24, CHUNK_ID_WIDTH)
                report "trigger fifo repeated an already consumed descriptor while read side was busy"
                severity failure;
        end loop;

        wait_for_read_valid(rd_valid, 80);
        wait for 1 ns;
        assert rd_chunk_id = to_unsigned(99, CHUNK_ID_WIDTH)
            report "trigger fifo did not advance to the next descriptor after read side became ready"
            severity failure;
        assert rd_score = std_logic_vector(to_signed(1999, 32))
            report "trigger fifo next descriptor score mismatch"
            severity failure;
        assert rd_timestamp = to_unsigned(199, TIMESTAMP_WIDTH)
            report "trigger fifo next descriptor timestamp mismatch"
            severity failure;
        rd_ready <= '1';
        wait until rising_edge(rd_clk);
        rd_ready <= '0';

        report "tb_trigger_cdc_fifo passed";
        stop;
    end process;
end architecture sim;
