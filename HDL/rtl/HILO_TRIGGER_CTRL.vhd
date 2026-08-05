library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity HILO_TRIGGER_CTRL is
    generic (
        RATE_WINDOW_CYCLES : positive := 12500
    );
    port (
        CLK                 : in  std_logic;
        RST                 : in  std_logic;
        ACTIVE_MODE         : in  std_logic_vector(3 downto 0);
        MODE_START          : in  std_logic;

        HL_DATA_STR         : in  std_logic;
        HL_ADC_DATA4        : in  work.PRE_TRIGGER_pkg.adc_data4_type;
        HL_ANCHOR_CHUNK     : in  chunk_id_t;
        HL_ANCHOR_OFFSET    : in  beat_offset_t;
        HL_ANCHOR_TIME      : in  timestamp_t;

        HL_THRESH           : in  std_logic_vector(11 downto 0);
        HILO_WINDOW         : in  std_logic_vector(4 downto 0);
        COINC_WINDOW        : in  std_logic_vector(5 downto 0);
        BIN_THR             : in  std_logic_vector(3 downto 0);

        EVENT_REQUEST_VALID : out std_logic;
        EVENT_REQUEST_READY : in  std_logic;
        EVENT_REQUEST       : out event_request_t;
        GATED_WORK_VALID    : out std_logic;
        GATED_WORK_READY    : in  std_logic;
        GATED_WORK          : out event_request_t;
        EVENT_FINISHED      : in  std_logic;
        REQUEST_FAILED      : in  std_logic;

        BUSY                : out std_logic;
        HILO_BLANKING       : out std_logic;
        HILO_CONFIG_ERROR   : out std_logic;
        EVENT_LOSS_PULSE    : out std_logic
    );
end entity HILO_TRIGGER_CTRL;

architecture rtl of HILO_TRIGGER_CTRL is
    constant RATE_ENTER_THRESHOLD : integer := 15;
    constant RATE_EXIT_THRESHOLD  : integer := 3;

    type chunk_pipe_t is array (0 to 1) of chunk_id_t;
    type offset_pipe_t is array (0 to 1) of beat_offset_t;
    type timestamp_pipe_t is array (0 to 1) of timestamp_t;

    signal latched_thresh_r       : std_logic_vector(11 downto 0) := (others => '0');
    signal latched_hilo_window_r  : std_logic_vector(4 downto 0) := (others => '0');
    signal latched_coinc_window_r : std_logic_vector(5 downto 0) := (others => '0');
    signal latched_bin_thr_r      : std_logic_vector(3 downto 0) := x"1";
    signal config_valid_r         : std_logic := '0';

    signal pre_trigger_reset_r  : std_logic := '1';
    signal pre_trigger_data_str : std_logic;
    signal pre_trigger_result   : std_logic;
    signal pre_trigger_bin_thr  : std_logic_vector(3 downto 0);

    signal result_valid_pipe_r : std_logic_vector(0 to 1) := (others => '0');
    signal anchor_chunk_pipe_r : chunk_pipe_t := (others => (others => '0'));
    signal anchor_offset_pipe_r : offset_pipe_t := (others => (others => '0'));
    signal anchor_time_pipe_r : timestamp_pipe_t := (others => (others => '0'));

    signal event_request_valid_r : std_logic := '0';
    signal gated_work_valid_r    : std_logic := '0';
    signal request_r             : event_request_t := NULL_EVENT_REQUEST;
    signal window_busy_r         : std_logic := '0';
    signal blanking_r            : std_logic := '0';
    signal previous_hilo_r       : std_logic := '0';
    signal rate_timer_r          : integer range 0 to RATE_WINDOW_CYCLES - 1 := 0;
    signal rate_count_r          : integer range 0 to RATE_ENTER_THRESHOLD := 0;
    signal event_loss_pulse_r    : std_logic := '0';

    function is_hilo_mode(mode_value : std_logic_vector(3 downto 0))
        return boolean is
    begin
        return mode_value = TRIGGER_MODE_HILO or
               mode_value = TRIGGER_MODE_HILO_AI;
    end function;

    function config_is_valid(
        threshold_value : std_logic_vector(11 downto 0);
        bin_value       : std_logic_vector(3 downto 0)
    ) return boolean is
    begin
        return threshold_value(11) = '0' and
               unsigned(bin_value) >= 1 and unsigned(bin_value) <= 4;
    end function;
begin
    -- PRE_TRIGGER uses RESET as an asynchronous clear internally.  Register
    -- the mode-entry pulse so a combinational RST/MODE_START LUT cannot glitch
    -- those reset pins.
    process (CLK)
    begin
        if rising_edge(CLK) then
            pre_trigger_reset_r <= RST or MODE_START;
        end if;
    end process;

    -- PRE_TRIGGER v2.2.4 treats BIN_THR=0 as an unconditional trigger.  Keep
    -- its physical input fail-closed even while the externally supplied
    -- configuration is invalid; config_valid_r still reports and rejects it.
    pre_trigger_bin_thr <= latched_bin_thr_r when
        unsigned(latched_bin_thr_r) >= 1 and unsigned(latched_bin_thr_r) <= 4
        else x"1";
    pre_trigger_data_str <= HL_DATA_STR when
        is_hilo_mode(ACTIVE_MODE) and config_valid_r = '1' and
        MODE_START = '0' and pre_trigger_reset_r = '0' else '0';

    u_PRE_TRIGGER : entity work.PRE_TRIGGER
        port map (
            CLK          => CLK,
            RESET        => pre_trigger_reset_r,
            DATA_STR     => pre_trigger_data_str,
            ADC_DATA4    => HL_ADC_DATA4,
            THRESH       => latched_thresh_r,
            HILO_WINDOW  => latched_hilo_window_r,
            COINC_WINDOW => latched_coinc_window_r,
            BIN_THR      => pre_trigger_bin_thr,
            PRE_TRIG     => pre_trigger_result
        );

    process (CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' or MODE_START = '1' then
                result_valid_pipe_r <= (others => '0');
                anchor_chunk_pipe_r <= (others => (others => '0'));
                anchor_offset_pipe_r <= (others => (others => '0'));
                anchor_time_pipe_r <= (others => (others => '0'));
            else
                result_valid_pipe_r(1) <= result_valid_pipe_r(0);
                result_valid_pipe_r(0) <= pre_trigger_data_str;
                anchor_chunk_pipe_r(1) <= anchor_chunk_pipe_r(0);
                anchor_offset_pipe_r(1) <= anchor_offset_pipe_r(0);
                anchor_time_pipe_r(1) <= anchor_time_pipe_r(0);
                if pre_trigger_data_str = '1' then
                    anchor_chunk_pipe_r(0) <= HL_ANCHOR_CHUNK;
                    anchor_offset_pipe_r(0) <= HL_ANCHOR_OFFSET;
                    anchor_time_pipe_r(0) <= HL_ANCHOR_TIME;
                end if;
            end if;
        end if;
    end process;

    process (CLK)
        variable anchor_address : logical_beat_t;
        variable count_v        : integer range 0 to RATE_ENTER_THRESHOLD;
        variable raw_l0         : boolean;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                latched_thresh_r       <= (others => '0');
                latched_hilo_window_r  <= (others => '0');
                latched_coinc_window_r <= (others => '0');
                latched_bin_thr_r      <= x"1";
                config_valid_r         <= '0';
                event_request_valid_r  <= '0';
                gated_work_valid_r     <= '0';
                request_r              <= NULL_EVENT_REQUEST;
                window_busy_r          <= '0';
                blanking_r             <= '0';
                previous_hilo_r        <= '0';
                rate_timer_r           <= 0;
                rate_count_r           <= 0;
                event_loss_pulse_r     <= '0';
            else
                event_loss_pulse_r <= '0';
                if is_hilo_mode(ACTIVE_MODE) then
                    previous_hilo_r <= '1';
                else
                    previous_hilo_r <= '0';
                end if;

                if MODE_START = '1' then
                    latched_thresh_r       <= HL_THRESH;
                    latched_hilo_window_r  <= HILO_WINDOW;
                    latched_coinc_window_r <= COINC_WINDOW;
                    latched_bin_thr_r      <= BIN_THR;
                    if is_hilo_mode(ACTIVE_MODE) and
                       config_is_valid(HL_THRESH, BIN_THR) then
                        config_valid_r <= '1';
                    else
                        config_valid_r <= '0';
                    end if;
                    event_request_valid_r <= '0';
                    gated_work_valid_r    <= '0';
                    window_busy_r         <= '0';
                    rate_timer_r          <= 0;
                    rate_count_r          <= 0;
                    if previous_hilo_r = '0' then
                        blanking_r <= '0';
                    end if;
                else
                    if event_request_valid_r = '1' and EVENT_REQUEST_READY = '1' then
                        event_request_valid_r <= '0';
                    end if;
                    if gated_work_valid_r = '1' and GATED_WORK_READY = '1' then
                        gated_work_valid_r <= '0';
                        window_busy_r      <= '0';
                    end if;
                    if EVENT_FINISHED = '1' or REQUEST_FAILED = '1' then
                        event_request_valid_r <= '0';
                        window_busy_r         <= '0';
                    end if;

                    count_v := rate_count_r;
                    raw_l0 := result_valid_pipe_r(1) = '1' and
                              pre_trigger_result = '1' and
                              config_valid_r = '1' and
                              is_hilo_mode(ACTIVE_MODE);
                    if raw_l0 and count_v < RATE_ENTER_THRESHOLD then
                        count_v := count_v + 1;
                    end if;

                    if raw_l0 and blanking_r = '0' then
                        if window_busy_r = '1' then
                            event_loss_pulse_r <= '1';
                        else
                            anchor_address.chunk_id    := anchor_chunk_pipe_r(1);
                            anchor_address.beat_offset := anchor_offset_pipe_r(1);
                            request_r.start_address <= subtract_beats(anchor_address, 31);
                            request_r.event_timestamp <= anchor_time_pipe_r(1);
                            request_r.trigger_offset <= anchor_offset_pipe_r(1);
                            request_r.score <= (others => '0');
                            window_busy_r <= '1';
                            if ACTIVE_MODE = TRIGGER_MODE_HILO then
                                event_request_valid_r <= '1';
                            elsif ACTIVE_MODE = TRIGGER_MODE_HILO_AI then
                                gated_work_valid_r <= '1';
                            end if;
                        end if;
                    end if;

                    if rate_timer_r = RATE_WINDOW_CYCLES - 1 then
                        rate_timer_r <= 0;
                        rate_count_r <= 0;
                        if count_v >= RATE_ENTER_THRESHOLD then
                            blanking_r <= '1';
                        elsif count_v <= RATE_EXIT_THRESHOLD and window_busy_r = '0' then
                            blanking_r <= '0';
                        end if;
                    else
                        rate_timer_r <= rate_timer_r + 1;
                        rate_count_r <= count_v;
                    end if;
                end if;
            end if;
        end if;
    end process;

    EVENT_REQUEST_VALID <= event_request_valid_r;
    EVENT_REQUEST       <= request_r;
    GATED_WORK_VALID    <= gated_work_valid_r;
    GATED_WORK          <= request_r;
    BUSY <= window_busy_r or event_request_valid_r or gated_work_valid_r or
            result_valid_pipe_r(0) or result_valid_pipe_r(1);
    HILO_BLANKING <= blanking_r when is_hilo_mode(ACTIVE_MODE) else '0';
    HILO_CONFIG_ERROR <= '1' when is_hilo_mode(ACTIVE_MODE) and
        config_valid_r = '0' else '0';
    EVENT_LOSS_PULSE <= event_loss_pulse_r;
end architecture rtl;
