library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_multimode_runtime_switch is
end entity tb_multimode_runtime_switch;

architecture sim of tb_multimode_runtime_switch is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal data_str : std_logic := '0';
    signal adc_data4 : adc_data4_t := (others => (others => (others => '0')));
    signal requested_mode : std_logic_vector(3 downto 0) := TRIGGER_MODE_CAPTURE_ALL;
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

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                intermediate_mode_seen <= '0';
            elsif active_mode = TRIGGER_MODE_AI or
                  active_mode = TRIGGER_MODE_HILO then
                intermediate_mode_seen <= '1';
            end if;
        end if;
    end process;

    process
        variable last_seen : integer := 0;
        variable quiet_cycles : integer := 0;
    begin
        wait until rising_edge(clk);
        rst <= '0';

        for chunk_value in 0 to 2 loop
            for beat_value in 0 to N_BATCHES - 1 loop
                if chunk_value = 2 and beat_value = N_BATCHES - 1 then
                    requested_mode <= TRIGGER_MODE_AI;
                end if;
                drive_batch(adc_data4, chunk_value, beat_value);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = TRIGGER_MODE_CAPTURE_ALL and mode_pending = '1'
            report "a stalled output event did not hold the old active mode" severity failure;

        requested_mode <= TRIGGER_MODE_HILO;
        wait until rising_edge(clk);
        requested_mode <= TRIGGER_MODE_EXTERNAL;
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = TRIGGER_MODE_CAPTURE_ALL and mode_pending = '1'
            report "pending requests must not apply while the output path is stalled" severity failure;

        event_ready <= '1';
        while quiet_cycles < 8 loop
            wait until rising_edge(clk);
            if event_valid = '1' then
                quiet_cycles := 0;
                if event_last = '1' then
                    last_seen := last_seen + 1;
                end if;
            elsif last_seen > 0 then
                quiet_cycles := quiet_cycles + 1;
            end if;
        end loop;
        assert active_mode = TRIGGER_MODE_CAPTURE_ALL and mode_pending = '1'
            report "drain completion alone applied a mode without a chunk boundary" severity failure;

        for beat_value in 0 to N_BATCHES - 1 loop
            drive_batch(adc_data4, 3, beat_value);
            data_str <= '1';
            wait until rising_edge(clk);
        end loop;
        data_str <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;

        assert active_mode = TRIGGER_MODE_EXTERNAL and mode_pending = '0' and
               intermediate_mode_seen = '0' and invalid_mode = '0'
            report "safe runtime switch did not apply only the latest requested mode"
            severity failure;
        assert event_loss = '0'
            report "a lossless mode drain reported EVENT_LOSS" severity failure;
        report "tb_multimode_runtime_switch passed";
        stop;
        wait;
    end process;
end architecture sim;
