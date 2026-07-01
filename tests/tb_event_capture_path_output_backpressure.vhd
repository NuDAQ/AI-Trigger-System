library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_capture_path_output_backpressure is
end entity tb_event_capture_path_output_backpressure;

architecture sim of tb_event_capture_path_output_backpressure is
    signal clk_adc          : std_logic := '0';
    signal clk_cnn          : std_logic := '0';
    signal rst              : std_logic := '1';
    signal data_str         : std_logic := '0';
    signal adc_data4        : adc_data4_t;
    signal score_valid      : std_logic := '0';
    signal score_data       : std_logic_vector(31 downto 0) := (others => '0');
    signal score_chunk_id   : chunk_id_t := (others => '0');
    signal score_timestamp  : timestamp_t := (others => '0');
    signal cnn_thresh       : std_logic_vector(31 downto 0) := (others => '0');
    signal event_valid      : std_logic;
    signal event_ready      : std_logic := '1';
    signal event_data       : raw_adc_batch_t;
    signal event_last       : std_logic;
    signal event_chunk_id   : chunk_id_t;
    signal event_timestamp  : timestamp_t;
    signal event_score      : std_logic_vector(31 downto 0);
    signal dropped_trigger_count : unsigned(31 downto 0);
    signal ring_miss_count       : unsigned(31 downto 0);

    function sample_value(chunk_id : integer; batch_id : integer; ch : integer; sample : integer)
        return std_logic_vector is
        variable v : integer;
    begin
        v := chunk_id * 257 + batch_id * 17 + ch * 5 + sample;
        return std_logic_vector(to_unsigned(v mod 4096, 12));
    end function;

    function expected_batch(chunk_id : integer; batch_id : integer) return raw_adc_batch_t is
        variable packed : raw_adc_batch_t := (others => '0');
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                packed((ch * N_BATCH_S + s) * 12 + 11 downto
                       (ch * N_BATCH_S + s) * 12) :=
                    sample_value(chunk_id, batch_id, ch, s);
            end loop;
        end loop;
        return packed;
    end function;

    procedure drive_batch(signal target : out adc_data4_t; chunk_id : integer; batch_id : integer) is
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                target(ch)(s) <= sample_value(chunk_id, batch_id, ch, s);
            end loop;
        end loop;
    end procedure;
begin
    clk_adc <= not clk_adc after 8 ns;
    clk_cnn <= not clk_cnn after 3 ns;

    u_dut : entity work.EVENT_CAPTURE_PATH
        port map (
            CLK_ADC        => clk_adc,
            CLK_CNN        => clk_cnn,
            RST_ADC        => rst,
            RST_CNN        => rst,
            DATA_STR       => data_str,
            ADC_DATA4      => adc_data4,
            SCORE_VALID    => score_valid,
            SCORE_DATA     => score_data,
            SCORE_CHUNK_ID => score_chunk_id,
            SCORE_TIMESTAMP => score_timestamp,
            CNN_THRESH     => cnn_thresh,
            EVENT_VALID    => event_valid,
            EVENT_READY    => event_ready,
            EVENT_DATA     => event_data,
            EVENT_LAST     => event_last,
            EVENT_CHUNK_ID => event_chunk_id,
            EVENT_TIMESTAMP => event_timestamp,
            EVENT_SCORE    => event_score,
            DROPPED_TRIGGER_COUNT => dropped_trigger_count,
            RING_MISS_COUNT       => ring_miss_count
        );

    process
        variable seen : integer := 0;
        variable expected_chunk : integer;
        variable expected_batch_idx : integer;
        variable wait_cycles : integer := 0;
    begin
        cnn_thresh <= std_logic_vector(to_signed(1024, 32));
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(s) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk_adc);
        rst <= '0';

        for c in 0 to 2 loop
            for b in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, c, b);
                data_str <= '1';
                wait until rising_edge(clk_adc);
            end loop;
        end loop;
        data_str <= '0';

        event_ready <= '0';
        for trig in 1 to 2 loop
            wait until rising_edge(clk_cnn);
            score_valid     <= '1';
            score_data      <= std_logic_vector(to_signed(2048 + trig, 32));
            score_chunk_id  <= to_unsigned(trig, CHUNK_ID_WIDTH);
            score_timestamp <= to_unsigned(100 + trig, TIMESTAMP_WIDTH);
            wait until rising_edge(clk_cnn);
            score_valid <= '0';
        end loop;

        for i in 0 to 200 loop
            wait until rising_edge(clk_adc);
        end loop;

        for c in 3 to WAVEFORM_RING_DEPTH + 8 loop
            for b in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, c, b);
                data_str <= '1';
                wait until rising_edge(clk_adc);
            end loop;
        end loop;
        data_str <= '0';

        event_ready <= '1';
        while seen < 2 * N_BATCHES loop
            wait until rising_edge(clk_adc);
            wait for 1 ns;
            if event_valid = '1' then
                expected_chunk := 1 + seen / N_BATCHES;
                expected_batch_idx := seen mod N_BATCHES;
                assert event_chunk_id = to_unsigned(expected_chunk, CHUNK_ID_WIDTH)
                    report "buffered event chunk id mismatch"
                    severity failure;
                assert event_timestamp = to_unsigned(100 + expected_chunk, TIMESTAMP_WIDTH)
                    report "buffered event timestamp mismatch"
                    severity failure;
                assert event_score = std_logic_vector(to_signed(2048 + expected_chunk, 32))
                    report "buffered event score mismatch"
                    severity failure;
                assert event_data = expected_batch(expected_chunk, expected_batch_idx)
                    report "buffered event waveform was not preserved across output backpressure"
                    severity failure;
                if expected_batch_idx = N_BATCHES - 1 then
                    assert event_last = '1'
                        report "final buffered event beat must assert event_last"
                        severity failure;
                else
                    assert event_last = '0'
                        report "non-final buffered event beat must not assert event_last"
                        severity failure;
                end if;
                seen := seen + 1;
                wait_cycles := 0;
            else
                wait_cycles := wait_cycles + 1;
                assert wait_cycles < 800
                    report "timed out waiting for internally buffered events"
                    severity failure;
            end if;
        end loop;

        assert ring_miss_count = to_unsigned(0, ring_miss_count'length)
            report "output backpressure must not cause ring misses for buffered events"
            severity failure;
        assert dropped_trigger_count = to_unsigned(0, dropped_trigger_count'length)
            report "output backpressure must not drop buffered triggers"
            severity failure;

        report "tb_event_capture_path_output_backpressure passed";
        stop;
    end process;
end architecture sim;
