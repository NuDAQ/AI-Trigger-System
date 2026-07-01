library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_adc_input_cdc_fifo is
end entity tb_adc_input_cdc_fifo;

architecture tb of tb_adc_input_cdc_fifo is
    signal src_clk : std_logic := '0';
    signal rd_clk  : std_logic := '0';
    signal rst     : std_logic := '1';

    signal wr_valid : std_logic := '0';
    signal wr_ready : std_logic;
    signal wr_data  : raw_adc_batch_t := (others => '0');

    signal rd_valid : std_logic;
    signal rd_ready : std_logic := '1';
    signal rd_data  : raw_adc_batch_t;

    signal overflow_count : unsigned(31 downto 0);

    function batch_word(value : natural) return raw_adc_batch_t is
    begin
        return std_logic_vector(to_unsigned(value, RAW_ADC_BATCH_WIDTH));
    end function;
begin
    src_clk <= not src_clk after 7 ns;
    rd_clk  <= not rd_clk after 5 ns;

    dut : entity work.ADC_INPUT_CDC_FIFO
        port map (
            WR_CLK         => src_clk,
            RST_ASYNC      => rst,
            WR_RST         => rst,
            WR_VALID       => wr_valid,
            WR_READY       => wr_ready,
            WR_DATA        => wr_data,
            RD_CLK         => rd_clk,
            RD_RST         => rst,
            RD_VALID       => rd_valid,
            RD_READY       => rd_ready,
            RD_DATA        => rd_data,
            OVERFLOW_COUNT => overflow_count
        );

    stimulus : process
    begin
        wait for 40 ns;
        rst <= '0';
        wait until rising_edge(src_clk);

        for i in 0 to 2 loop
            wr_data <= batch_word(16#100# + i);
            wr_valid <= '1';
            wait until rising_edge(src_clk);
            assert wr_ready = '1'
                report "input FIFO did not accept source beat"
                severity failure;
            wr_valid <= '0';
            wait until rising_edge(src_clk);
        end loop;

        wait for 200 ns;
        assert false report "end simulation" severity failure;
    end process;

    monitor : process
        variable seen : integer := 0;
    begin
        wait until rst = '0';
        while seen < 3 loop
            wait until rising_edge(rd_clk);
            if rd_valid = '1' and rd_ready = '1' then
                assert rd_data = batch_word(16#100# + seen)
                    report "ADC input CDC FIFO output order mismatch"
                    severity failure;
                seen := seen + 1;
            end if;
        end loop;

        assert overflow_count = to_unsigned(0, overflow_count'length)
            report "unexpected ADC input FIFO overflow"
            severity failure;
        wait for 20 ns;
        stop;
    end process;
end architecture tb;
