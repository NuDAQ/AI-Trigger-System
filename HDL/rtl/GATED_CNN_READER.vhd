library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity GATED_CNN_READER is
    port (
        CLK                  : in  std_logic;
        RST                  : in  std_logic;
        WORK_VALID           : in  std_logic;
        WORK_READY           : out std_logic;
        WORK_VALUE           : in  event_request_t;
        CNN_THRESH           : in  std_logic_vector(31 downto 0);
        LANE_BUSY            : in  lane_busy_t;

        CHECK_START_CHUNK_ID : out chunk_id_t;
        CHECK_START_OFFSET   : out beat_offset_t;
        CHECK_PRESENT        : in  std_logic;
        CHECK_PROTECTED      : in  std_logic;
        CHECK_EXPIRED        : in  std_logic;

        RING_REQUEST         : out std_logic;
        RING_GRANT           : in  std_logic;
        RING_DONE            : out std_logic;
        RB_RD_EN             : out std_logic;
        RB_RD_CHUNK_ID       : out chunk_id_t;
        RB_RD_BATCH_IDX      : out integer range 0 to N_BATCHES - 1;
        RB_RD_DATA           : in  raw_adc_batch_t;
        RB_RD_VALID          : in  std_logic;
        RB_RD_HIT            : in  std_logic;

        LANE_WE              : out std_logic_vector(N_LANES - 1 downto 0);
        BATCH_DATA           : out std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
        LANE_START_CHUNK     : out chunk_id_t;
        LANE_START_OFFSET    : out beat_offset_t;
        LANE_TIMESTAMP       : out timestamp_t;
        LANE_TRIGGER_OFFSET  : out beat_offset_t;
        LANE_THRESH          : out std_logic_vector(31 downto 0);

        BUSY                 : out std_logic;
        EVENT_LOSS_PULSE     : out std_logic
    );
end entity GATED_CNN_READER;

architecture rtl of GATED_CNN_READER is
    type state_t is (IDLE, READING, WAIT_DROP);
    signal state_r          : state_t := IDLE;
    signal priority_r       : integer range 0 to N_LANES - 1 := 0;
    signal candidate_lane_s : integer range -1 to N_LANES - 1 := -1;
    signal selected_lane_r  : integer range 0 to N_LANES - 1 := 0;
    signal active_work_r    : event_request_t := NULL_EVENT_REQUEST;
    signal active_thresh_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal issue_count_r    : integer range 0 to N_BATCHES := 0;
    signal response_count_r : integer range 0 to N_BATCHES := 0;
    signal rb_rd_en_r       : std_logic := '0';
    signal rb_rd_chunk_id_r : chunk_id_t := (others => '0');
    signal rb_rd_batch_idx_r : integer range 0 to N_BATCHES - 1 := 0;
    signal ring_done_r      : std_logic := '0';
    signal event_loss_pulse_r : std_logic := '0';
begin
    process (LANE_BUSY, priority_r)
        variable selected_v : integer range -1 to N_LANES - 1;
        variable lane_idx   : integer range 0 to N_LANES - 1;
    begin
        selected_v := -1;
        for offset in 0 to N_LANES - 1 loop
            lane_idx := (priority_r + offset) mod N_LANES;
            if selected_v = -1 and LANE_BUSY(lane_idx) = '0' then
                selected_v := lane_idx;
            end if;
        end loop;
        candidate_lane_s <= selected_v;
    end process;

    process (CLK)
        variable issue_address : logical_beat_t;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state_r            <= IDLE;
                priority_r         <= 0;
                selected_lane_r    <= 0;
                active_work_r      <= NULL_EVENT_REQUEST;
                active_thresh_r    <= (others => '0');
                issue_count_r      <= 0;
                response_count_r   <= 0;
                rb_rd_en_r         <= '0';
                rb_rd_chunk_id_r   <= (others => '0');
                rb_rd_batch_idx_r  <= 0;
                ring_done_r        <= '0';
                event_loss_pulse_r <= '0';
            else
                rb_rd_en_r         <= '0';
                ring_done_r        <= '0';
                event_loss_pulse_r <= '0';

                case state_r is
                    when IDLE =>
                        issue_count_r    <= 0;
                        response_count_r <= 0;
                        if WORK_VALID = '1' and CHECK_EXPIRED = '1' then
                            event_loss_pulse_r <= '1';
                            state_r <= WAIT_DROP;
                        elsif WORK_VALID = '1' and CHECK_PRESENT = '1' and
                              CHECK_PROTECTED = '1' and candidate_lane_s >= 0 and
                              RING_GRANT = '1' then
                            active_work_r   <= WORK_VALUE;
                            active_thresh_r <= CNN_THRESH;
                            selected_lane_r <= candidate_lane_s;
                            issue_address := WORK_VALUE.start_address;
                            rb_rd_en_r        <= '1';
                            rb_rd_chunk_id_r  <= issue_address.chunk_id;
                            rb_rd_batch_idx_r <= to_integer(issue_address.beat_offset);
                            issue_count_r    <= 1;
                            response_count_r <= 0;
                            state_r <= READING;
                        end if;

                    when READING =>
                        if issue_count_r < N_BATCHES then
                            issue_address := add_beats(active_work_r.start_address,
                                                       issue_count_r);
                            rb_rd_en_r        <= '1';
                            rb_rd_chunk_id_r  <= issue_address.chunk_id;
                            rb_rd_batch_idx_r <= to_integer(issue_address.beat_offset);
                            issue_count_r <= issue_count_r + 1;
                        end if;

                        if RB_RD_VALID = '1' then
                            -- synthesis translate_off
                            assert RB_RD_HIT = '1'
                                report "protected gated-CNN ring transaction missed"
                                severity failure;
                            -- synthesis translate_on
                            if RB_RD_HIT = '0' then
                                event_loss_pulse_r <= '1';
                            end if;

                            if response_count_r = N_BATCHES - 1 then
                                response_count_r <= N_BATCHES;
                                ring_done_r <= '1';
                                if selected_lane_r = N_LANES - 1 then
                                    priority_r <= 0;
                                else
                                    priority_r <= selected_lane_r + 1;
                                end if;
                                state_r <= WAIT_DROP;
                            else
                                response_count_r <= response_count_r + 1;
                            end if;
                        end if;

                    when WAIT_DROP =>
                        if WORK_VALID = '0' then
                            state_r <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    CHECK_START_CHUNK_ID <= WORK_VALUE.start_address.chunk_id;
    CHECK_START_OFFSET   <= WORK_VALUE.start_address.beat_offset;
    RING_REQUEST <= '1' when state_r = IDLE and WORK_VALID = '1' and
        CHECK_PRESENT = '1' and CHECK_PROTECTED = '1' and
        candidate_lane_s >= 0 else '0';
    RING_DONE <= ring_done_r;

    RB_RD_EN        <= rb_rd_en_r;
    RB_RD_CHUNK_ID  <= rb_rd_chunk_id_r;
    RB_RD_BATCH_IDX <= rb_rd_batch_idx_r;

    process (state_r, RB_RD_VALID, RB_RD_HIT, selected_lane_r)
        variable lane_we_v : std_logic_vector(N_LANES - 1 downto 0);
    begin
        lane_we_v := (others => '0');
        if state_r = READING and RB_RD_VALID = '1' and RB_RD_HIT = '1' then
            lane_we_v(selected_lane_r) := '1';
        end if;
        LANE_WE <= lane_we_v;
    end process;

    BATCH_DATA          <= pack_cnn_raw_batch(RB_RD_DATA);
    LANE_START_CHUNK    <= active_work_r.start_address.chunk_id;
    LANE_START_OFFSET   <= active_work_r.start_address.beat_offset;
    LANE_TIMESTAMP      <= active_work_r.event_timestamp;
    LANE_TRIGGER_OFFSET <= active_work_r.trigger_offset;
    LANE_THRESH         <= active_thresh_r;

    WORK_READY <= '1' when state_r = WAIT_DROP else '0';
    BUSY <= '1' when state_r /= IDLE or WORK_VALID = '1' else '0';
    EVENT_LOSS_PULSE <= event_loss_pulse_r;
end architecture rtl;
