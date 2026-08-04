library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity HOUSEKEEPING_TRIGGER_CTRL is
    port (
        CLK                  : in  std_logic;
        RST                  : in  std_logic;
        ACTIVE_MODE          : in  std_logic_vector(3 downto 0);
        MODE_START           : in  std_logic;
        ACCEPT_NEW_WORK      : in  std_logic;

        DATA_STR             : in  std_logic;
        WRITE_CHUNK_ID       : in  chunk_id_t;
        WRITE_BEAT_OFFSET    : in  beat_offset_t;
        WRITE_TIMESTAMP      : in  timestamp_t;
        CHUNK_COMMIT         : in  std_logic;
        COMMIT_CHUNK_ID      : in  chunk_id_t;
        COMMIT_TIMESTAMP     : in  timestamp_t;
        FORCE_TRIGGER        : in  std_logic;

        REQUEST_VALID        : out std_logic;
        REQUEST_READY        : in  std_logic;
        REQUEST_VALUE        : out event_request_t;
        EVENT_FINISHED       : in  std_logic;
        REQUEST_FAILED       : in  std_logic;

        BUSY                 : out std_logic;
        EVENT_LOSS_PULSE     : out std_logic
    );
end entity HOUSEKEEPING_TRIGGER_CTRL;

architecture rtl of HOUSEKEEPING_TRIGGER_CTRL is
    constant CAPTURE_BACKLOG_MAX : integer := WAVEFORM_RING_DEPTH - 4;

    signal capture_oldest_id_r : chunk_id_t := (others => '0');
    signal capture_oldest_timestamp_r : timestamp_t := (others => '0');
    signal capture_backlog_r : integer range 0 to CAPTURE_BACKLOG_MAX := 0;

    signal external_armed_r       : std_logic := '0';
    signal external_wait_valid_r  : std_logic := '0';
    signal external_request_valid_r : std_logic := '0';
    signal external_busy_r        : std_logic := '0';
    signal external_request_r     : event_request_t := NULL_EVENT_REQUEST;
    signal event_loss_pulse_r     : std_logic := '0';

    signal capture_request : event_request_t;
begin
    process (CLK)
        variable backlog_v : integer range 0 to CAPTURE_BACKLOG_MAX;
        variable oldest_id_v : chunk_id_t;
        variable oldest_timestamp_v : timestamp_t;
        variable anchor_address : logical_beat_t;
        variable centered_start : logical_beat_t;
        variable capture_fire : boolean;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                capture_oldest_id_r        <= (others => '0');
                capture_oldest_timestamp_r <= (others => '0');
                capture_backlog_r          <= 0;
                external_armed_r           <= '0';
                external_wait_valid_r      <= '0';
                external_request_valid_r   <= '0';
                external_busy_r            <= '0';
                external_request_r         <= NULL_EVENT_REQUEST;
                event_loss_pulse_r         <= '0';
            else
                event_loss_pulse_r <= '0';

                if MODE_START = '1' then
                    capture_backlog_r        <= 0;
                    external_armed_r         <= '0';
                    external_wait_valid_r    <= '0';
                    external_request_valid_r <= '0';
                    external_busy_r          <= '0';
                else
                    backlog_v := capture_backlog_r;
                    oldest_id_v := capture_oldest_id_r;
                    oldest_timestamp_v := capture_oldest_timestamp_r;
                    capture_fire :=
                        ACTIVE_MODE = TRIGGER_MODE_CAPTURE_ALL and
                        capture_backlog_r > 0 and REQUEST_READY = '1';

                    if capture_fire then
                        backlog_v := backlog_v - 1;
                        oldest_id_v := oldest_id_v + 1;
                        oldest_timestamp_v := oldest_timestamp_v + 1;
                    end if;

                    if ACTIVE_MODE = TRIGGER_MODE_CAPTURE_ALL and
                       ACCEPT_NEW_WORK = '1' and CHUNK_COMMIT = '1' then
                        if backlog_v < CAPTURE_BACKLOG_MAX then
                            if backlog_v = 0 then
                                oldest_id_v := COMMIT_CHUNK_ID;
                                oldest_timestamp_v := COMMIT_TIMESTAMP;
                            end if;
                            backlog_v := backlog_v + 1;
                        else
                            event_loss_pulse_r <= '1';
                        end if;
                    end if;

                    capture_backlog_r          <= backlog_v;
                    capture_oldest_id_r        <= oldest_id_v;
                    capture_oldest_timestamp_r <= oldest_timestamp_v;

                    if ACTIVE_MODE = TRIGGER_MODE_EXTERNAL then
                        if EVENT_FINISHED = '1' or REQUEST_FAILED = '1' then
                            external_busy_r          <= '0';
                            external_wait_valid_r     <= '0';
                            external_request_valid_r  <= '0';
                        end if;

                        if external_request_valid_r = '1' and REQUEST_READY = '1' then
                            external_request_valid_r <= '0';
                        end if;

                        if external_wait_valid_r = '1' and DATA_STR = '1' then
                            anchor_address.chunk_id    := WRITE_CHUNK_ID;
                            anchor_address.beat_offset := WRITE_BEAT_OFFSET;
                            centered_start := subtract_beats(anchor_address, 31);
                            external_request_r.start_address   <= centered_start;
                            external_request_r.event_timestamp <= WRITE_TIMESTAMP;
                            external_request_r.trigger_offset  <= WRITE_BEAT_OFFSET;
                            external_request_r.score           <= (others => '0');
                            external_wait_valid_r    <= '0';
                            external_request_valid_r <= '1';
                        end if;

                        if FORCE_TRIGGER = '0' then
                            external_armed_r <= '1';
                        elsif external_armed_r = '1' then
                            external_armed_r <= '0';
                            if ACCEPT_NEW_WORK = '1' then
                                if external_busy_r = '1' then
                                    event_loss_pulse_r <= '1';
                                else
                                    external_busy_r <= '1';
                                    if DATA_STR = '1' then
                                        anchor_address.chunk_id    := WRITE_CHUNK_ID;
                                        anchor_address.beat_offset := WRITE_BEAT_OFFSET;
                                        centered_start := subtract_beats(anchor_address, 31);
                                        external_request_r.start_address   <= centered_start;
                                        external_request_r.event_timestamp <= WRITE_TIMESTAMP;
                                        external_request_r.trigger_offset  <= WRITE_BEAT_OFFSET;
                                        external_request_r.score           <= (others => '0');
                                        external_request_valid_r <= '1';
                                    else
                                        external_wait_valid_r <= '1';
                                    end if;
                                end if;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    capture_request.start_address.chunk_id    <= capture_oldest_id_r;
    capture_request.start_address.beat_offset <= (others => '0');
    capture_request.event_timestamp <= capture_oldest_timestamp_r;
    capture_request.trigger_offset  <= (others => '0');
    capture_request.score           <= (others => '0');

    REQUEST_VALID <= '1' when
        ACTIVE_MODE = TRIGGER_MODE_CAPTURE_ALL and capture_backlog_r > 0
        else external_request_valid_r when ACTIVE_MODE = TRIGGER_MODE_EXTERNAL
        else '0';
    REQUEST_VALUE <= capture_request when ACTIVE_MODE = TRIGGER_MODE_CAPTURE_ALL
        else external_request_r;

    BUSY <= '1' when capture_backlog_r > 0 else
            external_busy_r or external_wait_valid_r or external_request_valid_r;
    EVENT_LOSS_PULSE <= event_loss_pulse_r;
end architecture rtl;
