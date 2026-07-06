library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_adc_chunk_distributor_timestamp is
end entity tb_adc_chunk_distributor_timestamp;

architecture sim of tb_adc_chunk_distributor_timestamp is
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
    signal metadata_sample_error : std_logic := '0';

    function adc_sample(value : integer) return adc_sample_t is
    begin
        return std_logic_vector(to_signed(value, 12));
    end function;

    function axis_sample(value : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(value / 2, 16));
    end function;
begin
    clk <= not clk after 5 ns;

    u_dut : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC         => clk,
            RST             => rst,
            DATA_STR        => data_str,
            ADC_DATA4       => adc_data4,
            LANE_BUSY       => lane_busy,
            LANE_WE         => lane_we,
            BATCH_DATA      => batch_data,
            CHUNK_ID        => chunk_id,
            CHUNK_TIMESTAMP => chunk_timestamp,
            CHUNK_OVERFLOW  => chunk_overflow
        );

    process
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(s) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst <= '0';

        adc_data4(0)(0) <= adc_sample(2);
        adc_data4(1)(0) <= adc_sample(4);
        adc_data4(2)(0) <= adc_sample(6);
        adc_data4(3)(0) <= adc_sample(8);
        adc_data4(4)(0) <= adc_sample(1000);
        adc_data4(5)(0) <= adc_sample(1002);
        adc_data4(6)(0) <= adc_sample(1004);
        adc_data4(7)(0) <= adc_sample(1006);

        for batch in 0 to 3 * N_BATCHES - 1 loop
            data_str <= '1';
            wait until rising_edge(clk);
            wait for 1 ns;
            assert lane_we /= (lane_we'range => '0')
                report "lane write should be asserted when all lanes are ready"
                severity failure;
            assert chunk_timestamp = resize(chunk_id, TIMESTAMP_WIDTH)
                report "chunk timestamp must match chunk id"
                severity failure;

            if batch = 0 then
                assert batch_data(911 downto 896) = axis_sample(2)
                    report "CNN packed row0 ch0 must come from input ch0"
                    severity failure;
                assert batch_data(927 downto 912) = axis_sample(4)
                    report "CNN packed row0 ch1 must come from input ch1"
                    severity failure;
                assert batch_data(943 downto 928) = axis_sample(6)
                    report "CNN packed row0 ch2 must come from input ch2"
                    severity failure;
                assert batch_data(959 downto 944) = axis_sample(8)
                    report "CNN packed row0 ch3 must come from input ch3"
                    severity failure;
            end if;
        end loop;

        data_str <= '0';
        wait until rising_edge(clk);
        report "tb_adc_chunk_distributor_timestamp passed";
        stop;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '0' and data_str = '1' and lane_we /= (lane_we'range => '0') then
                if chunk_timestamp /= resize(chunk_id, TIMESTAMP_WIDTH) then
                    metadata_sample_error <= '1';
                    assert false
                        report "lane-sampled chunk timestamp must match chunk id"
                        severity failure;
                end if;
            end if;
        end if;
    end process;
end architecture sim;
