library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_multimode_hilo_drain is
end entity tb_multimode_hilo_drain;

architecture sim of tb_multimode_hilo_drain is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal data_str : std_logic := '0';
    signal adc_data4 : adc_data4_t := (others => (others => (others => '0')));
    signal requested_mode : std_logic_vector(3 downto 0) := TRIGGER_MODE_HILO_AI;
    signal lane_busy : lane_busy_t := (others => '0');
    signal event_valid, event_ready, event_last : std_logic := '0';
    signal active_mode : std_logic_vector(3 downto 0);
    signal mode_pending, invalid_mode, event_loss : std_logic;
    signal intermediate_mode_seen : std_logic := '0';

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (chunk_value * N_BATCHES + beat_value + ch + sample_idx)
                    mod 2048, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.MULTIMODE_EVENT_PATH
        port map (
            CLK_ADC => clk, CLK_CNN => clk, RST_ADC => rst, RST_CNN => rst,
            DATA_STR => data_str, ADC_DATA4 => adc_data4,
            TRIGGER_MODE => requested_mode, FORCE_TRIGGER => '0',
            CNN_THRESH => (others => '0'), HL_THRESH => std_logic_vector(to_signed(100, 12)),
            HILO_WINDOW => std_logic_vector(to_unsigned(5, 5)),
            COINC_WINDOW => std_logic_vector(to_unsigned(3, 6)), BIN_THR => x"1",
            CNN_RESULT_VALID => '0', CNN_RESULT_READY => open,
            CNN_RESULT_REQUEST => NULL_EVENT_REQUEST, CNN_INPUT_BUSY_ADC => '0',
            CNN_WORK_PENDING_CNN => '0', CNN_CHUNK_OVERFLOW => '0',
            LIVE_AI_ENABLE => open, GATED_LANE_BUSY => lane_busy,
            GATED_LANE_WE => open, GATED_BATCH_DATA => open, GATED_START_CHUNK => open,
            GATED_START_OFFSET => open, GATED_TIMESTAMP => open,
            GATED_TRIGGER_OFFSET => open, GATED_THRESH => open,
            EVENT_VALID => event_valid, EVENT_READY => event_ready, EVENT_DATA => open,
            EVENT_LAST => event_last, EVENT_CHUNK_ID => open,
            EVENT_TIMESTAMP => open, EVENT_TRIGGER_OFFSET => open,
            EVENT_SCORE => open, ACTIVE_TRIGGER_MODE => active_mode,
            MODE_SWITCH_PENDING => mode_pending,
            INVALID_TRIGGER_MODE => invalid_mode,
            HILO_BLANKING => open, HILO_CONFIG_ERROR => open,
            EVENT_LOSS => event_loss, DROPPED_TRIGGER_COUNT => open,
            RING_MISS_COUNT => open
        );

    process
    begin
        wait until falling_edge(clk);
        rst <= '0';
        event_ready <= '1';
        -- Continuous startup leaves a partial Hi-Lo aggregate because mode
        -- entry is registered after the acquisition chunk boundary.
        data_str <= '1';
        for beat in 0 to 191 loop
            wait until falling_edge(clk);
        end loop;
        requested_mode <= TRIGGER_MODE_CAPTURE_ALL;
        for beat in 0 to 191 loop
            wait until falling_edge(clk);
        end loop;
        data_str <= '0';
        wait for 100 ns;
        assert active_mode = TRIGGER_MODE_CAPTURE_ALL and mode_pending = '0'
            report "partial Hi-Lo aggregate deadlocked runtime mode drain" severity failure;
        assert event_loss = '0' report "discarding incomplete Hi-Lo work reported event loss" severity failure;
        report "tb_multimode_hilo_drain passed";
        stop;
        wait;
    end process;
end architecture sim;
