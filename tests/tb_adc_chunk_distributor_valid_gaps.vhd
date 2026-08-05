library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_adc_chunk_distributor_valid_gaps is
end entity tb_adc_chunk_distributor_valid_gaps;

architecture sim of tb_adc_chunk_distributor_valid_gaps is
    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal data_str        : std_logic := '0';
    signal adc_data4       : adc_data4_t := (others => (others => (others => '0')));
    signal lane_busy       : lane_busy_t := (others => '0');
    signal lane_we         : std_logic_vector(N_LANES - 1 downto 0);
    signal batch_data      : std_logic_vector(N_BATCH_S * 64 - 1 downto 0);
    signal chunk_id        : chunk_id_t;
    signal chunk_timestamp : timestamp_t;
    signal chunk_overflow  : std_logic;
begin
    clk <= not clk after 5 ns;

    u_dut : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC         => clk,
            RST             => rst,
            DATA_STR        => data_str,
            ADC_DATA4       => adc_data4,
            ENABLE          => '1',
            LANE_BUSY       => lane_busy,
            LANE_WE         => lane_we,
            BATCH_DATA      => batch_data,
            CHUNK_ID        => chunk_id,
            CHUNK_TIMESTAMP => chunk_timestamp,
            CHUNK_OVERFLOW  => chunk_overflow
        );

    stimulus : process
    begin
        wait until rising_edge(clk);
        rst <= '0';

        wait until rising_edge(clk);
        data_str <= '1';

        wait until rising_edge(clk);
        data_str <= '0';

        wait until rising_edge(clk);
        data_str <= '1';

        wait until rising_edge(clk);
        wait until rising_edge(clk);
        report "tb_adc_chunk_distributor_valid_gaps passed";
        stop;
    end process;

    consumer_monitor : process
    begin
        wait until rising_edge(clk);
        if rst = '0' and data_str = '0' then
            assert lane_we = (lane_we'range => '0')
                report "lane write enable must not be sampled during a DATA_STR bubble"
                severity failure;
        end if;
    end process;
end architecture sim;
