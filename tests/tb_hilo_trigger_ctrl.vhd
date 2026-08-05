library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;
use work.PRE_TRIGGER_pkg.all;

entity tb_hilo_trigger_ctrl is
end entity tb_hilo_trigger_ctrl;

architecture sim of tb_hilo_trigger_ctrl is
    signal clk                 : std_logic := '0';
    signal rst                 : std_logic := '1';
    signal active_mode         : std_logic_vector(3 downto 0) := TRIGGER_MODE_HILO;
    signal mode_start          : std_logic := '0';
    signal hl_data_str         : std_logic := '0';
    signal hl_adc_data4        : adc_data4_type := (others => (others => (others => '0')));
    signal hl_anchor_chunk     : chunk_id_t := (others => '0');
    signal hl_anchor_offset    : beat_offset_t := (others => '0');
    signal hl_anchor_time      : timestamp_t := (others => '0');
    signal hl_thresh           : std_logic_vector(11 downto 0) := std_logic_vector(to_signed(100, 12));
    signal hilo_window         : std_logic_vector(4 downto 0) := std_logic_vector(to_unsigned(5, 5));
    signal coinc_window        : std_logic_vector(5 downto 0) := std_logic_vector(to_unsigned(3, 6));
    signal bin_thr             : std_logic_vector(3 downto 0) := x"1";
    signal event_request_valid : std_logic;
    signal event_request_ready : std_logic := '0';
    signal event_request       : event_request_t;
    signal gated_work_valid    : std_logic;
    signal gated_work_ready    : std_logic := '0';
    signal gated_work          : event_request_t;
    signal event_finished      : std_logic := '0';
    signal request_failed      : std_logic := '0';
    signal busy                : std_logic;
    signal blanking            : std_logic;
    signal config_error        : std_logic;
    signal event_loss_pulse    : std_logic;

    procedure drive_trigger_batch(signal target : out adc_data4_type) is
    begin
        target <= (others => (others => (others => '0')));
        target(0)(5) <= std_logic_vector(to_signed(200, 12));
        target(0)(8) <= std_logic_vector(to_signed(-200, 12));
    end procedure;

    procedure pulse_batch(signal strobe : out std_logic) is
    begin
        strobe <= '1';
        wait until rising_edge(clk);
        strobe <= '0';
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.HILO_TRIGGER_CTRL
        generic map (
            RATE_WINDOW_CYCLES => 64
        )
        port map (
            CLK                 => clk,
            RST                 => rst,
            ACTIVE_MODE         => active_mode,
            MODE_START          => mode_start,
            HL_DATA_STR         => hl_data_str,
            HL_ADC_DATA4        => hl_adc_data4,
            HL_ANCHOR_CHUNK     => hl_anchor_chunk,
            HL_ANCHOR_OFFSET    => hl_anchor_offset,
            HL_ANCHOR_TIME      => hl_anchor_time,
            HL_THRESH           => hl_thresh,
            HILO_WINDOW         => hilo_window,
            COINC_WINDOW        => coinc_window,
            BIN_THR             => bin_thr,
            EVENT_REQUEST_VALID => event_request_valid,
            EVENT_REQUEST_READY => event_request_ready,
            EVENT_REQUEST       => event_request,
            GATED_WORK_VALID    => gated_work_valid,
            GATED_WORK_READY    => gated_work_ready,
            GATED_WORK          => gated_work,
            EVENT_FINISHED      => event_finished,
            REQUEST_FAILED      => request_failed,
            BUSY                => busy,
            HILO_BLANKING       => blanking,
            HILO_CONFIG_ERROR   => config_error,
            EVENT_LOSS_PULSE    => event_loss_pulse
        );

    process
        variable wait_cycles : integer;
    begin
        drive_trigger_batch(hl_adc_data4);
        wait until rising_edge(clk);
        rst <= '0';

        mode_start <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert config_error = '0'
            report "valid Hi-Lo configuration was rejected" severity failure;

        hl_anchor_chunk  <= to_unsigned(7, CHUNK_ID_WIDTH);
        hl_anchor_offset <= to_unsigned(19, BEAT_OFFSET_WIDTH);
        hl_anchor_time   <= to_unsigned(77, TIMESTAMP_WIDTH);
        pulse_batch(hl_data_str);
        wait for 1 ps;
        assert event_request_valid = '0'
            report "Hi-Lo result was interpreted before its qualified pipeline cycle" severity failure;

        wait_cycles := 0;
        while event_request_valid = '0' loop
            wait until rising_edge(clk);
            wait for 1 ps;
            wait_cycles := wait_cycles + 1;
            assert wait_cycles < 8
                report "timed out waiting for qualified Hi-Lo result" severity failure;
        end loop;
        assert event_request.start_address.chunk_id = to_unsigned(6, CHUNK_ID_WIDTH) and
               event_request.start_address.beat_offset = to_unsigned(52, BEAT_OFFSET_WIDTH) and
               event_request.event_timestamp = to_unsigned(77, TIMESTAMP_WIDTH) and
               event_request.trigger_offset = to_unsigned(19, BEAT_OFFSET_WIDTH) and
               event_request.score = x"00000000"
            report "Hi-Lo Event Request is not aligned to its input batch" severity failure;

        event_request_ready <= '1';
        wait until rising_edge(clk);
        event_request_ready <= '0';
        wait for 1 ps;
        assert event_request_valid = '0' and busy = '1'
            report "standalone Hi-Lo must remain busy until event recording finishes" severity failure;

        pulse_batch(hl_data_str);
        wait_cycles := 0;
        while event_loss_pulse = '0' loop
            wait until rising_edge(clk);
            wait for 1 ps;
            wait_cycles := wait_cycles + 1;
            assert wait_cycles < 8
                report "busy-time Hi-Lo trigger was not reported as lost" severity failure;
        end loop;

        event_finished <= '1';
        wait until rising_edge(clk);
        event_finished <= '0';
        wait for 1 ps;
        assert busy = '0'
            report "Hi-Lo event completion did not release the active window" severity failure;

        hl_thresh  <= x"800";
        bin_thr    <= x"0";
        mode_start <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert config_error = '1'
            report "unsafe Hi-Lo configuration must assert config error" severity failure;
        pulse_batch(hl_data_str);
        for i in 0 to 5 loop
            wait until rising_edge(clk);
            wait for 1 ps;
            assert event_request_valid = '0' and gated_work_valid = '0'
                report "unsafe Hi-Lo configuration must fail closed" severity failure;
        end loop;

        hl_thresh   <= std_logic_vector(to_signed(100, 12));
        bin_thr     <= x"1";
        active_mode <= TRIGGER_MODE_HILO_AI;
        mode_start  <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        wait until rising_edge(clk);
        hl_anchor_chunk  <= to_unsigned(10, CHUNK_ID_WIDTH);
        hl_anchor_offset <= to_unsigned(40, BEAT_OFFSET_WIDTH);
        hl_anchor_time   <= to_unsigned(123, TIMESTAMP_WIDTH);
        pulse_batch(hl_data_str);

        wait_cycles := 0;
        while gated_work_valid = '0' loop
            wait until rising_edge(clk);
            wait for 1 ps;
            wait_cycles := wait_cycles + 1;
            assert wait_cycles < 8
                report "timed out waiting for Hi-Lo-gated AI work" severity failure;
        end loop;
        assert event_request_valid = '0' and
               gated_work.start_address.chunk_id = to_unsigned(10, CHUNK_ID_WIDTH) and
               gated_work.start_address.beat_offset = to_unsigned(9, BEAT_OFFSET_WIDTH) and
               gated_work.event_timestamp = to_unsigned(123, TIMESTAMP_WIDTH) and
               gated_work.trigger_offset = to_unsigned(40, BEAT_OFFSET_WIDTH)
            report "gated-AI work metadata is wrong" severity failure;

        gated_work_ready <= '1';
        wait until rising_edge(clk);
        gated_work_ready <= '0';
        wait for 1 ps;
        assert gated_work_valid = '0' and busy = '0'
            report "gated-AI work handoff must rearm the single Hi-Lo window" severity failure;

        mode_start <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        -- MODE_START is registered before it reaches PRE_TRIGGER's asynchronous
        -- clear pins; allow that reset pulse to deassert before counting raw
        -- decisions in the next rate window.
        wait until rising_edge(clk);
        gated_work_ready <= '1';
        hl_data_str <= '1';
        for i in 0 to 14 loop
            wait until rising_edge(clk);
        end loop;
        hl_data_str <= '0';

        wait_cycles := 0;
        while blanking = '0' loop
            wait until rising_edge(clk);
            wait for 1 ps;
            wait_cycles := wait_cycles + 1;
            assert wait_cycles < 70
                report "15 raw Hi-Lo decisions did not enter blanking" severity failure;
        end loop;

        wait_cycles := 0;
        while blanking = '1' loop
            wait until rising_edge(clk);
            wait for 1 ps;
            wait_cycles := wait_cycles + 1;
            assert wait_cycles < 80
                report "one quiet rate window did not leave blanking while idle" severity failure;
        end loop;
        gated_work_ready <= '0';

        report "tb_hilo_trigger_ctrl passed";
        stop;
        wait;
    end process;
end architecture sim;
