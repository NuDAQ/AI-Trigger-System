library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_drop_counters is
end entity tb_event_drop_counters;

architecture sim of tb_event_drop_counters is
    signal clk_adc               : std_logic := '0';
    signal clk_cnn               : std_logic := '0';
    signal rst                   : std_logic := '1';
    signal data_str              : std_logic := '0';
    signal adc_data4             : adc_data4_t;
    signal score_valid           : std_logic := '0';
    signal score_data            : std_logic_vector(31 downto 0) := (others => '0');
    signal score_chunk_id        : chunk_id_t := (others => '0');
    signal score_timestamp       : timestamp_t := (others => '0');
    signal cnn_thresh            : std_logic_vector(31 downto 0) := (others => '0');
    signal event_valid           : std_logic;
    signal event_ready           : std_logic := '0';
    signal event_data            : raw_adc_batch_t;
    signal event_last            : std_logic;
    signal event_chunk_id        : chunk_id_t;
    signal event_timestamp       : timestamp_t;
    signal event_score           : std_logic_vector(31 downto 0);
    signal dropped_trigger_count : unsigned(31 downto 0);
    signal ring_miss_count       : unsigned(31 downto 0);
begin
    clk_adc <= not clk_adc after 8 ns;
    clk_cnn <= not clk_cnn after 3 ns;

    u_dut : entity work.EVENT_CAPTURE_PATH
        port map (
            CLK_ADC               => clk_adc,
            CLK_CNN               => clk_cnn,
            RST_ADC               => rst,
            RST_CNN               => rst,
            DATA_STR              => data_str,
            ADC_DATA4             => adc_data4,
            SCORE_VALID           => score_valid,
            SCORE_DATA            => score_data,
            SCORE_CHUNK_ID        => score_chunk_id,
            SCORE_TIMESTAMP       => score_timestamp,
            CNN_THRESH            => cnn_thresh,
            EVENT_VALID           => event_valid,
            EVENT_READY           => event_ready,
            EVENT_DATA            => event_data,
            EVENT_LAST            => event_last,
            EVENT_CHUNK_ID        => event_chunk_id,
            EVENT_TIMESTAMP       => event_timestamp,
            EVENT_SCORE           => event_score,
            DROPPED_TRIGGER_COUNT => dropped_trigger_count,
            RING_MISS_COUNT       => ring_miss_count
        );

    process
    begin
        cnn_thresh <= (others => '0');
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(s) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk_adc);
        rst <= '0';
        wait until rising_edge(clk_cnn);

        for i in 0 to TRIGGER_FIFO_DEPTH + 8 loop
            score_valid    <= '1';
            score_data     <= std_logic_vector(to_signed(2048 + i, 32));
            score_chunk_id <= to_unsigned(i + 1, CHUNK_ID_WIDTH);
            score_timestamp <= to_unsigned(i + 1, TIMESTAMP_WIDTH);
            wait until rising_edge(clk_cnn);
            score_valid <= '0';
            wait until rising_edge(clk_cnn);
        end loop;

        for i in 0 to 80 loop
            wait until rising_edge(clk_cnn);
        end loop;

        assert dropped_trigger_count > 0
            report "overflowing the trigger FIFO must increment dropped_trigger_count"
            severity failure;
        assert ring_miss_count = 0
            report "no ring-buffer read was attempted, ring_miss_count must stay zero"
            severity failure;

        report "tb_event_drop_counters passed";
        stop;
    end process;
end architecture sim;
