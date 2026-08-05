library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_multimode_capture_all is
end entity tb_multimode_capture_all;

architecture sim of tb_multimode_capture_all is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal data_str : std_logic := '0';
    signal adc_data4 : adc_data4_t := (others => (others => (others => '0')));
    signal cnn_result_request : event_request_t := NULL_EVENT_REQUEST;
    signal cnn_result_ready : std_logic;
    signal live_ai_enable : std_logic;
    signal lane_busy : lane_busy_t := (others => '0');
    signal gated_lane_we : std_logic_vector(N_LANES - 1 downto 0);
    signal event_valid, event_last : std_logic;
    signal event_data : raw_adc_batch_t;
    signal event_chunk_id : chunk_id_t;
    signal event_timestamp : timestamp_t;
    signal event_offset : beat_offset_t;
    signal event_score : std_logic_vector(31 downto 0);
    signal active_mode : std_logic_vector(3 downto 0);
    signal mode_pending, invalid_mode, blanking, config_error, event_loss : std_logic;
    signal dropped_count, ring_miss_count : unsigned(31 downto 0);

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (chunk_value * 64 + beat_value + ch * 256) mod 4096, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.MULTIMODE_EVENT_PATH
        port map (
            CLK_ADC => clk, CLK_CNN => clk, RST_ADC => rst, RST_CNN => rst,
            DATA_STR => data_str, ADC_DATA4 => adc_data4,
            TRIGGER_MODE => TRIGGER_MODE_CAPTURE_ALL,
            FORCE_TRIGGER => '0', CNN_THRESH => (others => '0'),
            HL_THRESH => std_logic_vector(to_signed(100, 12)),
            HILO_WINDOW => std_logic_vector(to_unsigned(5, 5)),
            COINC_WINDOW => std_logic_vector(to_unsigned(3, 6)), BIN_THR => x"1",
            CNN_RESULT_VALID => '0', CNN_RESULT_READY => cnn_result_ready,
            CNN_RESULT_REQUEST => cnn_result_request,
            CNN_INPUT_BUSY_ADC => '0', CNN_WORK_PENDING_CNN => '0',
            CNN_CHUNK_OVERFLOW => '0', LIVE_AI_ENABLE => live_ai_enable,
            GATED_LANE_BUSY => lane_busy, GATED_LANE_WE => gated_lane_we,
            GATED_BATCH_DATA => open, GATED_START_CHUNK => open,
            GATED_START_OFFSET => open, GATED_TIMESTAMP => open,
            GATED_TRIGGER_OFFSET => open, GATED_THRESH => open,
            EVENT_VALID => event_valid, EVENT_READY => '1', EVENT_DATA => event_data,
            EVENT_LAST => event_last, EVENT_CHUNK_ID => event_chunk_id,
            EVENT_TIMESTAMP => event_timestamp, EVENT_TRIGGER_OFFSET => event_offset,
            EVENT_SCORE => event_score, ACTIVE_TRIGGER_MODE => active_mode,
            MODE_SWITCH_PENDING => mode_pending, INVALID_TRIGGER_MODE => invalid_mode,
            HILO_BLANKING => blanking, HILO_CONFIG_ERROR => config_error,
            EVENT_LOSS => event_loss, DROPPED_TRIGGER_COUNT => dropped_count,
            RING_MISS_COUNT => ring_miss_count
        );

    process
        variable seen : integer := 0;
        variable started : boolean := false;
        variable expected : integer;
    begin
        wait until rising_edge(clk);
        rst <= '0';

        for chunk_value in 0 to 2 loop
            for beat_value in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, chunk_value, beat_value);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';

        while seen < N_BATCHES loop
            wait until falling_edge(clk);
            if event_valid = '1' then
                started := true;
                expected := N_BATCHES + seen;
                assert to_integer(unsigned(event_data(11 downto 0))) = expected
                    report "Capture-All waveform order mismatch" severity failure;
                assert event_chunk_id = to_unsigned(1, CHUNK_ID_WIDTH) and
                       event_timestamp = to_unsigned(1, TIMESTAMP_WIDTH) and
                       event_offset = 0 and event_score = x"00000000"
                    report "Capture-All event metadata mismatch" severity failure;
                if seen = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "Capture-All final beat did not assert LAST" severity failure;
                else
                    assert event_last = '0'
                        report "Capture-All asserted LAST early" severity failure;
                end if;
                seen := seen + 1;
            elsif started then
                assert false report "Capture-All event contained a payload bubble" severity failure;
            end if;
        end loop;

        assert active_mode = TRIGGER_MODE_CAPTURE_ALL and mode_pending = '0' and
               invalid_mode = '0' and live_ai_enable = '0'
            report "Capture-All mode status mismatch" severity failure;
        assert event_loss = '0' and ring_miss_count = 0
            report "Capture-All unexpectedly reported event loss" severity failure;
        report "tb_multimode_capture_all passed";
        stop;
        wait;
    end process;
end architecture sim;
