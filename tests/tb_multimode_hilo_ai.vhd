library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_multimode_hilo_ai is
end entity tb_multimode_hilo_ai;

architecture sim of tb_multimode_hilo_ai is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal data_str : std_logic := '0';
    signal adc_data4 : adc_data4_t := (others => (others => (others => '0')));
    signal cnn_valid, cnn_ready : std_logic := '0';
    signal cnn_request : event_request_t := NULL_EVENT_REQUEST;
    signal lane_busy : lane_busy_t := (others => '0');
    signal live_ai_enable : std_logic;
    signal gated_lane_we : std_logic_vector(N_LANES - 1 downto 0);
    signal gated_batch_data : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal gated_start_chunk : chunk_id_t;
    signal gated_start_offset : beat_offset_t;
    signal gated_timestamp : timestamp_t;
    signal gated_trigger_offset : beat_offset_t;
    signal gated_thresh : std_logic_vector(31 downto 0);
    signal event_valid, event_last : std_logic;
    signal event_data : raw_adc_batch_t;
    signal event_timestamp : timestamp_t;
    signal event_offset : beat_offset_t;
    signal event_score : std_logic_vector(31 downto 0);
    signal active_mode : std_logic_vector(3 downto 0);
    signal config_error, event_loss : std_logic;
    signal gated_count : integer range 0 to N_BATCHES := 0;

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
        variable absolute_beat : integer;
    begin
        absolute_beat := chunk_value * N_BATCHES + beat_value;
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                if ch < N_TRIGGER_CH then
                    target(ch)(sample_idx) <= std_logic_vector(to_signed(
                        (absolute_beat + ch * 7 + sample_idx) mod 32, 12));
                else
                    target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                        (absolute_beat + ch * 256 + sample_idx) mod 2048, 12));
                end if;
            end loop;
        end loop;
        if chunk_value = 1 and beat_value = 3 then
            target(0)(1) <= std_logic_vector(to_signed(200, 12));
        elsif chunk_value = 1 and beat_value = 4 then
            target(0)(0) <= std_logic_vector(to_signed(-200, 12));
        end if;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.MULTIMODE_EVENT_PATH
        port map (
            CLK_ADC => clk, CLK_CNN => clk, RST_ADC => rst, RST_CNN => rst,
            DATA_STR => data_str, ADC_DATA4 => adc_data4,
            TRIGGER_MODE => TRIGGER_MODE_HILO_AI, FORCE_TRIGGER => '0',
            CNN_THRESH => x"00000010", HL_THRESH => std_logic_vector(to_signed(100, 12)),
            HILO_WINDOW => std_logic_vector(to_unsigned(5, 5)),
            COINC_WINDOW => std_logic_vector(to_unsigned(3, 6)), BIN_THR => x"1",
            CNN_RESULT_VALID => cnn_valid, CNN_RESULT_READY => cnn_ready,
            CNN_RESULT_REQUEST => cnn_request, CNN_INPUT_BUSY_ADC => '0',
            CNN_WORK_PENDING_CNN => '0', CNN_CHUNK_OVERFLOW => '0',
            LIVE_AI_ENABLE => live_ai_enable, GATED_LANE_BUSY => lane_busy,
            GATED_LANE_WE => gated_lane_we, GATED_BATCH_DATA => gated_batch_data,
            GATED_START_CHUNK => gated_start_chunk,
            GATED_START_OFFSET => gated_start_offset,
            GATED_TIMESTAMP => gated_timestamp,
            GATED_TRIGGER_OFFSET => gated_trigger_offset,
            GATED_THRESH => gated_thresh,
            EVENT_VALID => event_valid, EVENT_READY => '1', EVENT_DATA => event_data,
            EVENT_LAST => event_last, EVENT_CHUNK_ID => open,
            EVENT_TIMESTAMP => event_timestamp, EVENT_TRIGGER_OFFSET => event_offset,
            EVENT_SCORE => event_score, ACTIVE_TRIGGER_MODE => active_mode,
            MODE_SWITCH_PENDING => open, INVALID_TRIGGER_MODE => open,
            HILO_BLANKING => open, HILO_CONFIG_ERROR => config_error,
            EVENT_LOSS => event_loss, DROPPED_TRIGGER_COUNT => open,
            RING_MISS_COUNT => open
        );

    gated_monitor : process
        variable selected_lane : integer := -1;
        variable expected_sample : adc_sample_t;
        variable absolute_beat : integer;
    begin
        wait until falling_edge(clk);
        if rst = '1' then
            gated_count <= 0;
            selected_lane := -1;
        elsif gated_lane_we /= (gated_lane_we'range => '0') then
            if selected_lane < 0 then
                for lane_idx in 0 to N_LANES - 1 loop
                    if gated_lane_we(lane_idx) = '1' then
                        selected_lane := lane_idx;
                    end if;
                end loop;
            end if;
            assert selected_lane >= 0 and gated_lane_we(selected_lane) = '1'
                report "gated CNN window changed lanes mid-transfer" severity failure;
            assert gated_start_chunk = to_unsigned(0, CHUNK_ID_WIDTH) and
                   gated_start_offset = to_unsigned(38, BEAT_OFFSET_WIDTH) and
                   gated_timestamp = to_unsigned(1, TIMESTAMP_WIDTH) and
                   gated_trigger_offset = to_unsigned(5, BEAT_OFFSET_WIDTH) and
                   gated_thresh = x"00000010"
                report "Hi-Lo metadata was not preserved into the shared CNN lane" severity failure;
            absolute_beat := 38 + gated_count;
            expected_sample := std_logic_vector(to_signed(
                (absolute_beat + 7) mod 32, 12));
            assert gated_batch_data(31 downto 16) = adc_to_axis16(expected_sample)
                report "gated CNN reader changed the selected waveform order at beat " &
                       integer'image(gated_count) & ": got " &
                       integer'image(to_integer(signed(gated_batch_data(31 downto 16)))) &
                       ", expected " &
                       integer'image(to_integer(signed(adc_to_axis16(expected_sample))))
                severity failure;
            if gated_count < N_BATCHES then
                gated_count <= gated_count + 1;
            end if;
        end if;
    end process;

    process
        variable event_seen : integer := 0;
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
        assert active_mode = TRIGGER_MODE_HILO_AI and live_ai_enable = '0' and
               config_error = '0'
            report "HL+AI mode did not select the gated CNN path" severity failure;

        while gated_count < N_BATCHES loop
            wait until falling_edge(clk);
        end loop;

        cnn_request.start_address.chunk_id <= gated_start_chunk;
        cnn_request.start_address.beat_offset <= gated_start_offset;
        cnn_request.event_timestamp <= gated_timestamp;
        cnn_request.trigger_offset <= gated_trigger_offset;
        cnn_request.score <= x"00000123";
        cnn_valid <= '1';
        loop
            wait until rising_edge(clk);
            exit when cnn_ready = '1';
        end loop;
        cnn_valid <= '0';

        while event_seen < N_BATCHES loop
            wait until falling_edge(clk);
            if event_valid = '1' then
                absolute_beat := 38 + event_seen;
                assert to_integer(unsigned(event_data(
                    CH7_SAMPLE0_LSB + 11 downto CH7_SAMPLE0_LSB))) =
                    (absolute_beat + 7 * 256) mod 2048
                    report "HL+AI event did not reread the gated ring window" severity failure;
                assert event_timestamp = to_unsigned(1, TIMESTAMP_WIDTH) and
                       event_offset = to_unsigned(5, BEAT_OFFSET_WIDTH) and
                       event_score = x"00000123"
                    report "CNN result did not retain the Hi-Lo Event Request metadata" severity failure;
                if event_seen = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "HL+AI event final beat did not assert LAST" severity failure;
                end if;
                event_seen := event_seen + 1;
            end if;
        end loop;

        assert event_loss = '0'
            report "HL+AI system path reported a spurious event loss" severity failure;
        report "tb_multimode_hilo_ai passed";
        stop;
        wait;
    end process;
end architecture sim;
