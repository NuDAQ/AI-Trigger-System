library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity EVENT_CAPTURE_CTRL is
    port (
        CLK              : in  std_logic;
        RST              : in  std_logic;

        CHUNK_COMMIT     : in  std_logic;
        COMMIT_CHUNK_ID  : in  chunk_id_t;

        TRIGGER_VALID    : in  std_logic;
        TRIGGER_READY    : out std_logic;
        TRIGGER_CHUNK_ID : in  chunk_id_t;
        TRIGGER_SCORE    : in  std_logic_vector(31 downto 0);
        TRIGGER_TIMESTAMP : in timestamp_t;

        RB_RD_EN         : out std_logic;
        RB_RD_CHUNK_ID   : out chunk_id_t;
        RB_RD_BATCH_IDX  : out integer range 0 to N_BATCHES - 1;
        RB_RD_DATA       : in  raw_adc_batch_t;
        RB_RD_VALID      : in  std_logic;
        RB_RD_HIT        : in  std_logic;

        EVENT_VALID      : out std_logic;
        EVENT_READY      : in  std_logic;
        EVENT_DATA       : out raw_adc_batch_t;
        EVENT_LAST       : out std_logic;
        EVENT_CHUNK_ID   : out chunk_id_t;
        EVENT_TIMESTAMP  : out timestamp_t;
        EVENT_SCORE      : out std_logic_vector(31 downto 0);

        RING_MISS_COUNT  : out unsigned(31 downto 0)
    );
end entity EVENT_CAPTURE_CTRL;

architecture rtl of EVENT_CAPTURE_CTRL is
    signal latest_commit_id : chunk_id_t := (others => '0');
    signal have_commit : std_logic := '0';

    signal active_valid     : std_logic := '0';
    signal active_chunk_id : chunk_id_t := (others => '0');
    signal active_score    : std_logic_vector(31 downto 0) := (others => '0');
    signal active_timestamp : timestamp_t := (others => '0');
    signal active_chunk_offset : integer range 0 to EVENT_CHUNKS - 1 := 0;
    signal active_batch_idx    : integer range 0 to N_BATCHES - 1 := 0;

    signal pending_valid     : std_logic := '0';
    signal pending_chunk_id  : chunk_id_t := (others => '0');
    signal pending_score     : std_logic_vector(31 downto 0) := (others => '0');
    signal pending_timestamp : timestamp_t := (others => '0');

    signal rb_rd_en_r        : std_logic := '0';
    signal rb_rd_chunk_id_r  : chunk_id_t := (others => '0');
    signal rb_rd_batch_idx_r : integer range 0 to N_BATCHES - 1 := 0;

    type chunk_id_pipe_t is array (0 to 1) of chunk_id_t;
    type timestamp_pipe_t is array (0 to 1) of timestamp_t;
    type score_pipe_t is array (0 to 1) of std_logic_vector(31 downto 0);
    signal request_valid_pipe     : std_logic_vector(0 to 1) := (others => '0');
    signal request_last_pipe      : std_logic_vector(0 to 1) := (others => '0');
    signal request_chunk_id_pipe  : chunk_id_pipe_t := (others => (others => '0'));
    signal request_timestamp_pipe : timestamp_pipe_t := (others => (others => '0'));
    signal request_score_pipe     : score_pipe_t := (others => (others => '0'));

    constant RESPONSE_QUEUE_DEPTH : integer := 4;
    type response_data_mem_t is array (0 to RESPONSE_QUEUE_DEPTH - 1) of raw_adc_batch_t;
    type response_bit_mem_t is array (0 to RESPONSE_QUEUE_DEPTH - 1) of std_logic;
    type response_chunk_id_mem_t is array (0 to RESPONSE_QUEUE_DEPTH - 1) of chunk_id_t;
    type response_timestamp_mem_t is array (0 to RESPONSE_QUEUE_DEPTH - 1) of timestamp_t;
    type response_score_mem_t is array (0 to RESPONSE_QUEUE_DEPTH - 1) of std_logic_vector(31 downto 0);
    signal response_data_mem : response_data_mem_t := (others => (others => '0'));
    signal response_last_mem : response_bit_mem_t := (others => '0');
    signal response_chunk_id_mem : response_chunk_id_mem_t := (others => (others => '0'));
    signal response_timestamp_mem : response_timestamp_mem_t := (others => (others => '0'));
    signal response_score_mem : response_score_mem_t := (others => (others => '0'));
    signal response_read_ptr  : integer range 0 to RESPONSE_QUEUE_DEPTH - 1 := 0;
    signal response_write_ptr : integer range 0 to RESPONSE_QUEUE_DEPTH - 1 := 0;
    signal response_count     : integer range 0 to RESPONSE_QUEUE_DEPTH := 0;

    signal ring_miss_count_r : unsigned(31 downto 0) := (others => '0');

    function capture_ready(
        have_latest : std_logic;
        latest_id   : chunk_id_t;
        trigger_id  : chunk_id_t;
        commit_now  : std_logic;
        commit_id   : chunk_id_t
    ) return boolean is
        variable capture_last_id : chunk_id_t;
    begin
        capture_last_id :=
            trigger_id + to_unsigned(EVENT_CHUNKS - 1, CHUNK_ID_WIDTH);
        return (have_latest = '1' and latest_id >= capture_last_id) or
               (commit_now = '1' and commit_id >= capture_last_id);
    end function;

    function trigger_too_old(
        have_latest : std_logic;
        latest_id   : chunk_id_t;
        trigger_id  : chunk_id_t
    ) return boolean is
    begin
        return have_latest = '1' and
               latest_id >= trigger_id + to_unsigned(WAVEFORM_RING_DEPTH, CHUNK_ID_WIDTH);
    end function;

    function capture_chunk_id(trigger_id : chunk_id_t; offset : integer) return chunk_id_t is
    begin
        return trigger_id + to_unsigned(offset, CHUNK_ID_WIDTH);
    end function;

    function next_response_ptr(pointer : integer) return integer is
    begin
        if pointer = RESPONSE_QUEUE_DEPTH - 1 then
            return 0;
        else
            return pointer + 1;
        end if;
    end function;
begin
    process(CLK)
        variable pop_response  : boolean;
        variable push_response : boolean;
        variable trigger_fire  : boolean;
        variable final_request : boolean;
        variable reserved_slots : integer range 0 to RESPONSE_QUEUE_DEPTH + 2;
        variable miss_increments : integer range 0 to 2;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                latest_commit_id   <= (others => '0');
                have_commit        <= '0';
                active_valid       <= '0';
                active_chunk_id    <= (others => '0');
                active_score       <= (others => '0');
                active_timestamp   <= (others => '0');
                active_chunk_offset <= 0;
                active_batch_idx   <= 0;
                pending_valid      <= '0';
                pending_chunk_id   <= (others => '0');
                pending_score      <= (others => '0');
                pending_timestamp  <= (others => '0');
                rb_rd_en_r         <= '0';
                rb_rd_chunk_id_r   <= (others => '0');
                rb_rd_batch_idx_r  <= 0;
                request_valid_pipe <= (others => '0');
                request_last_pipe  <= (others => '0');
                request_chunk_id_pipe <= (others => (others => '0'));
                request_timestamp_pipe <= (others => (others => '0'));
                request_score_pipe <= (others => (others => '0'));
                response_read_ptr  <= 0;
                response_write_ptr <= 0;
                response_count     <= 0;
                ring_miss_count_r  <= (others => '0');
            else
                pop_response := response_count > 0 and EVENT_READY = '1';
                push_response :=
                    RB_RD_VALID = '1' and
                    request_valid_pipe(1) = '1' and
                    RB_RD_HIT = '1';
                trigger_fire :=
                    TRIGGER_VALID = '1' and pending_valid = '0';
                final_request := false;
                miss_increments := 0;

                rb_rd_en_r <= '0';
                request_valid_pipe(1) <= request_valid_pipe(0);
                request_valid_pipe(0) <= '0';
                request_last_pipe(1) <= request_last_pipe(0);
                request_chunk_id_pipe(1) <= request_chunk_id_pipe(0);
                request_timestamp_pipe(1) <= request_timestamp_pipe(0);
                request_score_pipe(1) <= request_score_pipe(0);

                if CHUNK_COMMIT = '1' then
                    latest_commit_id <= COMMIT_CHUNK_ID;
                    have_commit      <= '1';
                end if;

                -- The ring read response matches the request metadata delayed
                -- by the two registered process boundaries.
                -- synthesis translate_off
                assert not (
                    RB_RD_VALID = '1' and request_valid_pipe(1) = '0'
                )
                    report "ring-buffer response arrived without request metadata"
                    severity failure;
                assert not (
                    request_valid_pipe(1) = '1' and RB_RD_VALID = '0'
                )
                    report "ring-buffer request did not receive a response"
                    severity failure;
                -- synthesis translate_on

                if push_response then
                    assert response_count < RESPONSE_QUEUE_DEPTH or pop_response
                        report "event capture response queue overflow"
                        severity failure;
                    response_data_mem(response_write_ptr) <= RB_RD_DATA;
                    response_last_mem(response_write_ptr) <= request_last_pipe(1);
                    response_chunk_id_mem(response_write_ptr) <= request_chunk_id_pipe(1);
                    response_timestamp_mem(response_write_ptr) <= request_timestamp_pipe(1);
                    response_score_mem(response_write_ptr) <= request_score_pipe(1);
                    response_write_ptr <= next_response_ptr(response_write_ptr);
                elsif RB_RD_VALID = '1' and request_valid_pipe(1) = '1' then
                    miss_increments := miss_increments + 1;
                end if;

                if pop_response then
                    response_read_ptr <= next_response_ptr(response_read_ptr);
                end if;

                if push_response and not pop_response then
                    response_count <= response_count + 1;
                elsif pop_response and not push_response then
                    response_count <= response_count - 1;
                end if;

                reserved_slots := response_count;
                if request_valid_pipe(0) = '1' then
                    reserved_slots := reserved_slots + 1;
                end if;
                if request_valid_pipe(1) = '1' then
                    reserved_slots := reserved_slots + 1;
                end if;
                if pop_response then
                    reserved_slots := reserved_slots - 1;
                end if;
                if RB_RD_VALID = '1' and
                   request_valid_pipe(1) = '1' and
                   RB_RD_HIT = '0' then
                    reserved_slots := reserved_slots - 1;
                end if;

                if active_valid = '1' and
                   active_chunk_offset = 0 and
                   active_batch_idx = 0 and
                   trigger_too_old(
                       have_commit,
                       latest_commit_id,
                       active_chunk_id
                   ) then
                    active_valid <= '0';
                    miss_increments := miss_increments + 1;
                elsif active_valid = '1' and
                      capture_ready(
                          have_commit,
                          latest_commit_id,
                          active_chunk_id,
                          CHUNK_COMMIT,
                          COMMIT_CHUNK_ID
                      ) and
                      reserved_slots < RESPONSE_QUEUE_DEPTH then
                    final_request :=
                        active_chunk_offset = EVENT_CHUNKS - 1 and
                        active_batch_idx = N_BATCHES - 1;

                    rb_rd_en_r <= '1';
                    rb_rd_chunk_id_r <=
                        capture_chunk_id(
                            active_chunk_id,
                            active_chunk_offset
                        );
                    rb_rd_batch_idx_r <= active_batch_idx;
                    request_valid_pipe(0) <= '1';
                    if final_request then
                        request_last_pipe(0) <= '1';
                    else
                        request_last_pipe(0) <= '0';
                    end if;
                    request_chunk_id_pipe(0) <= active_chunk_id;
                    request_timestamp_pipe(0) <= active_timestamp;
                    request_score_pipe(0) <= active_score;

                    if final_request then
                        active_chunk_offset <= 0;
                        active_batch_idx <= 0;
                        if pending_valid = '1' then
                            active_valid <= '1';
                            active_chunk_id <= pending_chunk_id;
                            active_score <= pending_score;
                            active_timestamp <= pending_timestamp;
                            pending_valid <= '0';
                        elsif trigger_fire then
                            active_valid <= '1';
                            active_chunk_id <= TRIGGER_CHUNK_ID;
                            active_score <= TRIGGER_SCORE;
                            active_timestamp <= TRIGGER_TIMESTAMP;
                        else
                            active_valid <= '0';
                        end if;
                    elsif active_batch_idx = N_BATCHES - 1 then
                        active_batch_idx <= 0;
                        active_chunk_offset <=
                            (active_chunk_offset + 1) mod EVENT_CHUNKS;
                        if trigger_fire then
                            pending_valid <= '1';
                            pending_chunk_id <= TRIGGER_CHUNK_ID;
                            pending_score <= TRIGGER_SCORE;
                            pending_timestamp <= TRIGGER_TIMESTAMP;
                        end if;
                    else
                        active_batch_idx <= active_batch_idx + 1;
                        if trigger_fire then
                            pending_valid <= '1';
                            pending_chunk_id <= TRIGGER_CHUNK_ID;
                            pending_score <= TRIGGER_SCORE;
                            pending_timestamp <= TRIGGER_TIMESTAMP;
                        end if;
                    end if;
                elsif active_valid = '0' then
                    if pending_valid = '1' then
                        active_valid <= '1';
                        active_chunk_id <= pending_chunk_id;
                        active_score <= pending_score;
                        active_timestamp <= pending_timestamp;
                        active_chunk_offset <= 0;
                        active_batch_idx <= 0;
                        pending_valid <= '0';
                    elsif trigger_fire then
                        if trigger_too_old(
                            have_commit,
                            latest_commit_id,
                            TRIGGER_CHUNK_ID
                        ) then
                            miss_increments := miss_increments + 1;
                        elsif capture_ready(
                            have_commit,
                            latest_commit_id,
                            TRIGGER_CHUNK_ID,
                            CHUNK_COMMIT,
                            COMMIT_CHUNK_ID
                        ) and reserved_slots < RESPONSE_QUEUE_DEPTH then
                            -- Launch an already-readable idle trigger directly.
                            -- Deferring this first request through active_valid
                            -- inserts a one-cycle hole when a consecutive trigger
                            -- arrives just after the previous final request.
                            rb_rd_en_r <= '1';
                            rb_rd_chunk_id_r <= TRIGGER_CHUNK_ID;
                            rb_rd_batch_idx_r <= 0;
                            request_valid_pipe(0) <= '1';
                            if EVENT_CHUNKS = 1 and N_BATCHES = 1 then
                                request_last_pipe(0) <= '1';
                                active_valid <= '0';
                            else
                                request_last_pipe(0) <= '0';
                                active_valid <= '1';
                                active_chunk_id <= TRIGGER_CHUNK_ID;
                                active_score <= TRIGGER_SCORE;
                                active_timestamp <= TRIGGER_TIMESTAMP;
                                active_chunk_offset <= 0;
                                active_batch_idx <= 1;
                            end if;
                            request_chunk_id_pipe(0) <= TRIGGER_CHUNK_ID;
                            request_timestamp_pipe(0) <= TRIGGER_TIMESTAMP;
                            request_score_pipe(0) <= TRIGGER_SCORE;
                        else
                            active_valid <= '1';
                            active_chunk_id <= TRIGGER_CHUNK_ID;
                            active_score <= TRIGGER_SCORE;
                            active_timestamp <= TRIGGER_TIMESTAMP;
                            active_chunk_offset <= 0;
                            active_batch_idx <= 0;
                        end if;
                    end if;
                else
                    if trigger_fire then
                        pending_valid <= '1';
                        pending_chunk_id <= TRIGGER_CHUNK_ID;
                        pending_score <= TRIGGER_SCORE;
                        pending_timestamp <= TRIGGER_TIMESTAMP;
                    end if;
                end if;

                if miss_increments > 0 then
                    ring_miss_count_r <=
                        ring_miss_count_r +
                        to_unsigned(miss_increments, ring_miss_count_r'length);
                end if;
            end if;
        end if;
    end process;

    RB_RD_EN        <= rb_rd_en_r;
    RB_RD_CHUNK_ID  <= rb_rd_chunk_id_r;
    RB_RD_BATCH_IDX <= rb_rd_batch_idx_r;
    EVENT_VALID     <= '1' when response_count > 0 else '0';
    EVENT_DATA      <= response_data_mem(response_read_ptr);
    EVENT_LAST      <= response_last_mem(response_read_ptr);
    EVENT_CHUNK_ID  <= response_chunk_id_mem(response_read_ptr);
    EVENT_TIMESTAMP <= response_timestamp_mem(response_read_ptr);
    EVENT_SCORE     <= response_score_mem(response_read_ptr);
    TRIGGER_READY   <= not pending_valid;
    RING_MISS_COUNT <= ring_miss_count_r;
end architecture rtl;
