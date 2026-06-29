library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_capture_path is
end entity tb_event_capture_path;

architecture sim of tb_event_capture_path is
    signal clk_adc          : std_logic := '0';
    signal clk_cnn          : std_logic := '0';
    signal rst              : std_logic := '1';
    signal data_str         : std_logic := '0';
    signal adc_data4        : adc_data4_t;
    signal score_valid      : std_logic := '0';
    signal score_data       : std_logic_vector(31 downto 0) := (others => '0');
    signal score_chunk_id   : chunk_id_t := (others => '0');
    signal cnn_thresh       : std_logic_vector(31 downto 0) := (others => '0');
    signal event_valid      : std_logic;
    signal event_ready      : std_logic := '1';
    signal event_data       : raw_adc_batch_t;
    signal event_last       : std_logic;
    signal event_chunk_id   : chunk_id_t;
    signal event_score      : std_logic_vector(31 downto 0);

    function sample_value(chunk_id : integer; batch_id : integer; ch : integer; sample : integer)
        return std_logic_vector is
        variable v : integer;
    begin
        v := chunk_id * 256 + batch_id * 16 + ch * 4 + sample;
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

    function sample_at(batch : raw_adc_batch_t; ch : integer; sample : integer) return integer is
    begin
        return to_integer(unsigned(batch((ch * N_BATCH_S + sample) * 12 + 11 downto
                                         (ch * N_BATCH_S + sample) * 12)));
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
            RST            => rst,
            DATA_STR       => data_str,
            ADC_DATA4      => adc_data4,
            SCORE_VALID    => score_valid,
            SCORE_DATA     => score_data,
            SCORE_CHUNK_ID => score_chunk_id,
            CNN_THRESH     => cnn_thresh,
            EVENT_VALID    => event_valid,
            EVENT_READY    => event_ready,
            EVENT_DATA     => event_data,
            EVENT_LAST     => event_last,
            EVENT_CHUNK_ID => event_chunk_id,
            EVENT_SCORE    => event_score
        );

    process
        variable seen : integer := 0;
        variable chunk_expected : integer;
        variable batch_expected : integer;
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

        for c in 0 to 1 loop
            for b in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, c, b);
                data_str <= '1';
                wait until rising_edge(clk_adc);
            end loop;
        end loop;
        data_str <= '0';

        for trig in 1 to 2 loop
            wait until rising_edge(clk_cnn);
            score_valid    <= '1';
            score_data     <= std_logic_vector(to_signed(2048 + trig, 32));
            score_chunk_id <= to_unsigned(trig, CHUNK_ID_WIDTH);
            wait until rising_edge(clk_cnn);
            score_valid <= '0';
        end loop;

        for b in 0 to N_BATCHES - 1 loop
            drive_batch(adc_data4, 2, b);
            data_str <= '1';
            wait until rising_edge(clk_adc);
        end loop;
        data_str <= '0';

        while seen < EVENT_CHUNKS * N_BATCHES loop
            wait until rising_edge(clk_adc);
            wait for 1 ns;
            if event_valid = '1' then
                wait_cycles := 0;
                chunk_expected := seen / N_BATCHES;
                batch_expected := seen mod N_BATCHES;
                assert event_chunk_id = to_unsigned(1, CHUNK_ID_WIDTH)
                    report "first event path chunk id mismatch"
                    severity failure;
                assert event_score = std_logic_vector(to_signed(2049, 32))
                    report "first event path score mismatch"
                    severity failure;
                assert event_data = expected_batch(chunk_expected, batch_expected)
                    report "first event path waveform mismatch seen=" & integer'image(seen) &
                           " chunk=" & integer'image(chunk_expected) &
                           " batch=" & integer'image(batch_expected) &
                           " got0=" & integer'image(sample_at(event_data, 0, 0)) &
                           " got1=" & integer'image(sample_at(event_data, 0, 1)) &
                           " exp0=" & integer'image(sample_at(expected_batch(chunk_expected, batch_expected), 0, 0)) &
                           " exp1=" & integer'image(sample_at(expected_batch(chunk_expected, batch_expected), 0, 1))
                    severity failure;
                seen := seen + 1;
            else
                wait_cycles := wait_cycles + 1;
                assert wait_cycles < 600
                    report "timed out waiting for queued event capture"
                    severity failure;
            end if;
        end loop;

        assert event_last = '1'
            report "first event path final beat must assert event_last"
            severity failure;

        for b in 0 to N_BATCHES - 1 loop
            drive_batch(adc_data4, 3, b);
            data_str <= '1';
            wait until rising_edge(clk_adc);
        end loop;
        data_str <= '0';

        wait_cycles := 0;
        while seen < 2 * EVENT_CHUNKS * N_BATCHES loop
            wait until rising_edge(clk_adc);
            wait for 1 ns;
            if event_valid = '1' then
                wait_cycles := 0;
                chunk_expected := (seen / N_BATCHES) - EVENT_CHUNKS + 1;
                batch_expected := seen mod N_BATCHES;
                assert event_chunk_id = to_unsigned(2, CHUNK_ID_WIDTH)
                    report "second event path chunk id mismatch"
                    severity failure;
                assert event_score = std_logic_vector(to_signed(2050, 32))
                    report "second event path score mismatch"
                    severity failure;
                assert event_data = expected_batch(chunk_expected, batch_expected)
                    report "second event path waveform mismatch seen=" & integer'image(seen) &
                           " chunk=" & integer'image(chunk_expected) &
                           " batch=" & integer'image(batch_expected)
                    severity failure;
                seen := seen + 1;
            else
                wait_cycles := wait_cycles + 1;
                assert wait_cycles < 600
                    report "timed out waiting for second queued event capture"
                    severity failure;
            end if;
        end loop;

        assert event_last = '1'
            report "second event path final beat must assert event_last"
            severity failure;

        report "tb_event_capture_path passed";
        stop;
    end process;
end architecture sim;
