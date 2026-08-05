library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_multimode_ai is
end entity tb_multimode_ai;

architecture sim of tb_multimode_ai is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal data_str : std_logic := '0';
    signal adc_data4 : adc_data4_t := (others => (others => (others => '0')));
    signal cnn_valid, cnn_ready : std_logic := '0';
    signal cnn_request : event_request_t := NULL_EVENT_REQUEST;
    signal lane_busy : lane_busy_t := (others => '0');
    signal live_ai_enable : std_logic;
    signal event_valid, event_last : std_logic;
    signal event_data : raw_adc_batch_t;
    signal event_timestamp : timestamp_t;
    signal event_offset : beat_offset_t;
    signal event_score : std_logic_vector(31 downto 0);
    signal active_mode : std_logic_vector(3 downto 0);
    signal event_loss : std_logic;

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (chunk_value * N_BATCHES + beat_value + ch * 256 + sample_idx)
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
            TRIGGER_MODE => TRIGGER_MODE_AI, FORCE_TRIGGER => '0',
            CNN_THRESH => x"00000010", HL_THRESH => std_logic_vector(to_signed(100, 12)),
            HILO_WINDOW => std_logic_vector(to_unsigned(5, 5)),
            COINC_WINDOW => std_logic_vector(to_unsigned(3, 6)), BIN_THR => x"1",
            CNN_RESULT_VALID => cnn_valid, CNN_RESULT_READY => cnn_ready,
            CNN_RESULT_REQUEST => cnn_request, CNN_INPUT_BUSY_ADC => '0',
            CNN_WORK_PENDING_CNN => '0', CNN_CHUNK_OVERFLOW => '0',
            LIVE_AI_ENABLE => live_ai_enable, GATED_LANE_BUSY => lane_busy,
            GATED_LANE_WE => open, GATED_BATCH_DATA => open, GATED_START_CHUNK => open,
            GATED_START_OFFSET => open, GATED_TIMESTAMP => open,
            GATED_TRIGGER_OFFSET => open, GATED_THRESH => open,
            EVENT_VALID => event_valid, EVENT_READY => '1', EVENT_DATA => event_data,
            EVENT_LAST => event_last, EVENT_CHUNK_ID => open,
            EVENT_TIMESTAMP => event_timestamp, EVENT_TRIGGER_OFFSET => event_offset,
            EVENT_SCORE => event_score, ACTIVE_TRIGGER_MODE => active_mode,
            MODE_SWITCH_PENDING => open, INVALID_TRIGGER_MODE => open,
            HILO_BLANKING => open, HILO_CONFIG_ERROR => open,
            EVENT_LOSS => event_loss, DROPPED_TRIGGER_COUNT => open,
            RING_MISS_COUNT => open
        );

    process
        variable seen : integer := 0;
        variable started : boolean := false;
        variable absolute_beat : integer;
        constant CH7_SAMPLE0_LSB : integer := 7 * N_BATCH_S * 12;
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
        wait for 1 ps;
        assert active_mode = TRIGGER_MODE_AI and live_ai_enable = '1'
            report "AI mode did not activate its live distributor path" severity failure;

        cnn_request.start_address.chunk_id <= to_unsigned(0, CHUNK_ID_WIDTH);
        cnn_request.start_address.beat_offset <= to_unsigned(30, BEAT_OFFSET_WIDTH);
        cnn_request.event_timestamp <= to_unsigned(55, TIMESTAMP_WIDTH);
        cnn_request.trigger_offset <= to_unsigned(61, BEAT_OFFSET_WIDTH);
        cnn_request.score <= x"00000123";
        cnn_valid <= '1';
        loop
            wait until rising_edge(clk);
            exit when cnn_ready = '1';
        end loop;
        cnn_valid <= '0';

        while seen < N_BATCHES loop
            wait until falling_edge(clk);
            if event_valid = '1' then
                started := true;
                absolute_beat := 30 + seen;
                assert to_integer(unsigned(event_data(
                    CH7_SAMPLE0_LSB + 11 downto CH7_SAMPLE0_LSB))) =
                    (absolute_beat + 7 * 256) mod 2048
                    report "AI event did not retain channel 7 waveform order" severity failure;
                assert event_timestamp = to_unsigned(55, TIMESTAMP_WIDTH) and
                       event_offset = to_unsigned(61, BEAT_OFFSET_WIDTH) and
                       event_score = x"00000123"
                    report "AI Event Request metadata changed in the shared recorder" severity failure;
                if seen = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "AI event final beat did not assert LAST" severity failure;
                end if;
                seen := seen + 1;
            elsif started then
                assert false report "AI event contained a payload bubble" severity failure;
            end if;
        end loop;

        assert event_loss = '0'
            report "AI system path reported a spurious event loss" severity failure;
        report "tb_multimode_ai passed";
        stop;
        wait;
    end process;
end architecture sim;
