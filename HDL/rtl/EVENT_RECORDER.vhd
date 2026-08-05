library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity EVENT_RECORDER is
    port (
        CLK                   : in  std_logic;
        RST                   : in  std_logic;

        REQUEST_VALID         : in  std_logic;
        REQUEST_READY         : out std_logic;
        REQUEST_VALUE         : in  event_request_t;

        CHECK_VALID           : out std_logic;
        CHECK_START_CHUNK_ID  : out chunk_id_t;
        CHECK_START_OFFSET    : out beat_offset_t;
        CHECK_PRESENT         : in  std_logic;
        CHECK_PROTECTED       : in  std_logic;
        CHECK_EXPIRED         : in  std_logic;

        RING_REQUEST          : out std_logic;
        RING_GRANT            : in  std_logic;
        RING_DONE             : out std_logic;
        RING_CONTINUE         : out std_logic;
        RING_OWNER_ACTIVE     : out std_logic;

        RB_RD_EN              : out std_logic;
        RB_RD_CHUNK_ID        : out chunk_id_t;
        RB_RD_BATCH_IDX       : out integer range 0 to N_BATCHES - 1;
        RB_RD_DATA            : in  raw_adc_batch_t;
        RB_RD_VALID           : in  std_logic;
        RB_RD_HIT             : in  std_logic;

        EVENT_CREDIT          : in  std_logic;
        EVENT_VALID           : out std_logic;
        EVENT_READY           : in  std_logic;
        EVENT_DATA            : out raw_adc_batch_t;
        EVENT_LAST            : out std_logic;
        EVENT_CHUNK_ID        : out chunk_id_t;
        EVENT_TIMESTAMP       : out timestamp_t;
        EVENT_TRIGGER_OFFSET  : out beat_offset_t;
        EVENT_SCORE           : out std_logic_vector(31 downto 0);

        BUSY                  : out std_logic;
        EVENT_DONE_PULSE      : out std_logic;
        EVENT_LOSS_PULSE      : out std_logic;
        RING_MISS_COUNT       : out unsigned(31 downto 0)
    );
end entity EVENT_RECORDER;

architecture rtl of EVENT_RECORDER is
    type event_request_pipe_t is array (0 to 1) of event_request_t;

    signal active_valid_r  : std_logic := '0';
    signal active_request_r : event_request_t := NULL_EVENT_REQUEST;
    signal pending_valid_r : std_logic := '0';
    signal pending_request_r : event_request_t := NULL_EVENT_REQUEST;
    signal reading_r       : std_logic := '0';
    signal next_beat_r     : integer range 0 to N_BATCHES - 1 := 0;

    signal request_pipe_r  : event_request_pipe_t := (others => NULL_EVENT_REQUEST);
    signal request_valid_pipe_r : std_logic_vector(0 to 1) := (others => '0');
    signal request_last_pipe_r  : std_logic_vector(0 to 1) := (others => '0');

    signal rb_rd_en_r       : std_logic := '0';
    signal rb_rd_chunk_id_r : chunk_id_t := (others => '0');
    signal rb_rd_batch_idx_r : integer range 0 to N_BATCHES - 1 := 0;
    signal event_loss_pulse_r : std_logic := '0';
    signal ring_miss_count_r  : unsigned(31 downto 0) := (others => '0');
begin
    process (CLK)
        variable active_valid_v   : std_logic;
        variable active_request_v : event_request_t;
        variable pending_valid_v  : std_logic;
        variable pending_request_v : event_request_t;
        variable reading_v        : std_logic;
        variable next_beat_v      : integer range 0 to N_BATCHES - 1;
        variable issue_address    : logical_beat_t;
        variable request_fire     : boolean;
        variable miss_increment   : boolean;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                active_valid_r       <= '0';
                active_request_r     <= NULL_EVENT_REQUEST;
                pending_valid_r      <= '0';
                pending_request_r    <= NULL_EVENT_REQUEST;
                reading_r            <= '0';
                next_beat_r          <= 0;
                request_valid_pipe_r <= (others => '0');
                request_pipe_r       <= (others => NULL_EVENT_REQUEST);
                request_last_pipe_r  <= (others => '0');
                rb_rd_en_r           <= '0';
                rb_rd_chunk_id_r     <= (others => '0');
                rb_rd_batch_idx_r    <= 0;
                event_loss_pulse_r   <= '0';
                ring_miss_count_r    <= (others => '0');
            else
                active_valid_v    := active_valid_r;
                active_request_v  := active_request_r;
                pending_valid_v   := pending_valid_r;
                pending_request_v := pending_request_r;
                reading_v         := reading_r;
                next_beat_v       := next_beat_r;
                request_fire      := REQUEST_VALID = '1' and pending_valid_r = '0';
                miss_increment    := false;

                rb_rd_en_r         <= '0';
                event_loss_pulse_r <= '0';
                request_valid_pipe_r(1) <= request_valid_pipe_r(0);
                request_valid_pipe_r(0) <= '0';
                request_last_pipe_r(1)  <= request_last_pipe_r(0);
                request_pipe_r(1)       <= request_pipe_r(0);

                -- synthesis translate_off
                assert not (RB_RD_VALID = '1' and request_valid_pipe_r(1) = '0')
                    report "ring response arrived without Event Request metadata"
                    severity failure;
                assert not (request_valid_pipe_r(1) = '1' and RB_RD_VALID = '0')
                    report "Event Request ring read did not receive a response"
                    severity failure;
                assert not (
                    RB_RD_VALID = '1' and request_valid_pipe_r(1) = '1' and
                    RB_RD_HIT = '1' and EVENT_READY = '0'
                )
                    report "reserved event FIFO credit was not honored"
                    severity failure;
                -- synthesis translate_on

                if RB_RD_VALID = '1' and request_valid_pipe_r(1) = '1' and
                   RB_RD_HIT = '0' then
                    miss_increment := true;
                end if;

                if reading_v = '1' then
                    issue_address := add_beats(active_request_v.start_address, next_beat_v);
                    rb_rd_en_r        <= '1';
                    rb_rd_chunk_id_r  <= issue_address.chunk_id;
                    rb_rd_batch_idx_r <= to_integer(issue_address.beat_offset);
                    request_valid_pipe_r(0) <= '1';
                    request_pipe_r(0)       <= active_request_v;

                    if next_beat_v = N_BATCHES - 1 then
                        request_last_pipe_r(0) <= '1';
                        reading_v      := '0';
                        next_beat_v    := 0;
                        active_valid_v := pending_valid_v;
                        if pending_valid_v = '1' then
                            active_request_v := pending_request_v;
                        end if;
                        pending_valid_v := '0';
                    else
                        request_last_pipe_r(0) <= '0';
                        next_beat_v := next_beat_v + 1;
                    end if;
                elsif active_valid_v = '1' then
                    if CHECK_EXPIRED = '1' then
                        miss_increment := true;
                        active_valid_v := pending_valid_v;
                        if pending_valid_v = '1' then
                            active_request_v := pending_request_v;
                        end if;
                        pending_valid_v := '0';
                    elsif CHECK_PRESENT = '1' and CHECK_PROTECTED = '1' and
                          EVENT_CREDIT = '1' and RING_GRANT = '1' then
                        issue_address := active_request_v.start_address;
                        rb_rd_en_r        <= '1';
                        rb_rd_chunk_id_r  <= issue_address.chunk_id;
                        rb_rd_batch_idx_r <= to_integer(issue_address.beat_offset);
                        request_valid_pipe_r(0) <= '1';
                        request_last_pipe_r(0)  <= '0';
                        request_pipe_r(0)       <= active_request_v;
                        reading_v  := '1';
                        next_beat_v := 1;
                    end if;
                end if;

                if request_fire then
                    if active_valid_v = '0' then
                        active_valid_v   := '1';
                        active_request_v := REQUEST_VALUE;
                    else
                        pending_valid_v   := '1';
                        pending_request_v := REQUEST_VALUE;
                    end if;
                end if;

                if miss_increment then
                    ring_miss_count_r  <= ring_miss_count_r + 1;
                    event_loss_pulse_r <= '1';
                end if;

                active_valid_r    <= active_valid_v;
                active_request_r  <= active_request_v;
                pending_valid_r   <= pending_valid_v;
                pending_request_r <= pending_request_v;
                reading_r         <= reading_v;
                next_beat_r       <= next_beat_v;
            end if;
        end if;
    end process;

    CHECK_START_CHUNK_ID <= active_request_r.start_address.chunk_id
        when active_valid_r = '1' else (others => '0');
    CHECK_START_OFFSET <= active_request_r.start_address.beat_offset
        when active_valid_r = '1' else (others => '0');
    CHECK_VALID <= active_valid_r;
    RING_REQUEST <= '1' when active_valid_r = '1' and reading_r = '0' and
        CHECK_PRESENT = '1' and CHECK_PROTECTED = '1' and
        EVENT_CREDIT = '1' else '0';

    REQUEST_READY <= '1' when RST = '0' and pending_valid_r = '0' else '0';
    RB_RD_EN        <= rb_rd_en_r;
    RB_RD_CHUNK_ID  <= rb_rd_chunk_id_r;
    RB_RD_BATCH_IDX <= rb_rd_batch_idx_r;

    EVENT_VALID <= RB_RD_VALID and request_valid_pipe_r(1) and RB_RD_HIT;
    EVENT_DATA  <= RB_RD_DATA;
    EVENT_LAST  <= request_last_pipe_r(1);
    EVENT_CHUNK_ID <= request_pipe_r(1).start_address.chunk_id;
    EVENT_TIMESTAMP <= request_pipe_r(1).event_timestamp;
    EVENT_TRIGGER_OFFSET <= request_pipe_r(1).trigger_offset;
    EVENT_SCORE <= request_pipe_r(1).score;

    BUSY <= active_valid_r or pending_valid_r or reading_r or
            request_valid_pipe_r(0) or request_valid_pipe_r(1);
    EVENT_DONE_PULSE <= RB_RD_VALID and request_valid_pipe_r(1) and
                        RB_RD_HIT and EVENT_READY and request_last_pipe_r(1);
    RING_DONE <= RB_RD_VALID and request_valid_pipe_r(1) and
                 RB_RD_HIT and request_last_pipe_r(1);
    RING_CONTINUE <= reading_r;
    RING_OWNER_ACTIVE <= active_valid_r or pending_valid_r or reading_r or
                         request_valid_pipe_r(0) or request_valid_pipe_r(1);
    EVENT_LOSS_PULSE <= event_loss_pulse_r;
    RING_MISS_COUNT  <= ring_miss_count_r;
end architecture rtl;
