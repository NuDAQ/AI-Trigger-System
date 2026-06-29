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
        TRIGGER_CHUNK_ID : in  chunk_id_t;
        TRIGGER_SCORE    : in  std_logic_vector(31 downto 0);

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
        EVENT_SCORE      : out std_logic_vector(31 downto 0)
    );
end entity EVENT_CAPTURE_CTRL;

architecture rtl of EVENT_CAPTURE_CTRL is
    type state_t is (IDLE, WAIT_NEXT, ISSUE_READ, WAIT_READ);

    signal state : state_t := IDLE;
    signal latest_commit_id : chunk_id_t := (others => '0');
    signal have_commit : std_logic := '0';

    signal active_chunk_id : chunk_id_t := (others => '0');
    signal active_score    : std_logic_vector(31 downto 0) := (others => '0');
    signal chunk_offset    : integer range 0 to EVENT_CHUNKS - 1 := 0;
    signal batch_idx       : integer range 0 to N_BATCHES - 1 := 0;

    signal rb_rd_en_r        : std_logic := '0';
    signal rb_rd_chunk_id_r  : chunk_id_t := (others => '0');
    signal rb_rd_batch_idx_r : integer range 0 to N_BATCHES - 1 := 0;

    signal event_valid_r    : std_logic := '0';
    signal event_data_r     : raw_adc_batch_t := (others => '0');
    signal event_last_r     : std_logic := '0';
    signal event_chunk_id_r : chunk_id_t := (others => '0');
    signal event_score_r    : std_logic_vector(31 downto 0) := (others => '0');

    function next_chunk_ready(
        have_latest : std_logic;
        latest_id   : chunk_id_t;
        trigger_id  : chunk_id_t
    ) return boolean is
    begin
        return have_latest = '1' and latest_id >= trigger_id + 1;
    end function;

    function capture_chunk_id(trigger_id : chunk_id_t; offset : integer) return chunk_id_t is
    begin
        return trigger_id + to_unsigned(offset, CHUNK_ID_WIDTH) - 1;
    end function;

    procedure advance_position(
        signal offset : inout integer range 0 to EVENT_CHUNKS - 1;
        signal batch  : inout integer range 0 to N_BATCHES - 1;
        signal st     : out state_t
    ) is
    begin
        if batch = N_BATCHES - 1 then
            batch <= 0;
            if offset = EVENT_CHUNKS - 1 then
                offset <= 0;
                st <= IDLE;
            else
                offset <= offset + 1;
                st <= ISSUE_READ;
            end if;
        else
            batch <= batch + 1;
            st <= ISSUE_READ;
        end if;
    end procedure;
begin
    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state              <= IDLE;
                latest_commit_id   <= (others => '0');
                have_commit        <= '0';
                active_chunk_id    <= (others => '0');
                active_score       <= (others => '0');
                chunk_offset       <= 0;
                batch_idx          <= 0;
                rb_rd_en_r         <= '0';
                rb_rd_chunk_id_r   <= (others => '0');
                rb_rd_batch_idx_r  <= 0;
                event_valid_r      <= '0';
                event_data_r       <= (others => '0');
                event_last_r       <= '0';
                event_chunk_id_r   <= (others => '0');
                event_score_r      <= (others => '0');
            else
                rb_rd_en_r <= '0';

                if CHUNK_COMMIT = '1' then
                    latest_commit_id <= COMMIT_CHUNK_ID;
                    have_commit      <= '1';
                end if;

                if event_valid_r = '1' then
                    if EVENT_READY = '1' then
                        event_valid_r <= '0';
                        advance_position(chunk_offset, batch_idx, state);
                    end if;
                else
                    case state is
                        when IDLE =>
                            if TRIGGER_VALID = '1' then
                                active_chunk_id <= TRIGGER_CHUNK_ID;
                                active_score    <= TRIGGER_SCORE;
                                chunk_offset    <= 0;
                                batch_idx       <= 0;
                                if next_chunk_ready(have_commit, latest_commit_id, TRIGGER_CHUNK_ID) then
                                    state <= ISSUE_READ;
                                else
                                    state <= WAIT_NEXT;
                                end if;
                            end if;

                        when WAIT_NEXT =>
                            if next_chunk_ready(have_commit, latest_commit_id, active_chunk_id) or
                               (CHUNK_COMMIT = '1' and COMMIT_CHUNK_ID >= active_chunk_id + 1) then
                                state <= ISSUE_READ;
                            end if;

                        when ISSUE_READ =>
                            rb_rd_en_r        <= '1';
                            rb_rd_chunk_id_r  <= capture_chunk_id(active_chunk_id, chunk_offset);
                            rb_rd_batch_idx_r <= batch_idx;
                            state             <= WAIT_READ;

                        when WAIT_READ =>
                            if RB_RD_VALID = '1' then
                                if RB_RD_HIT = '1' then
                                    event_valid_r    <= '1';
                                    event_data_r     <= RB_RD_DATA;
                                    if chunk_offset = EVENT_CHUNKS - 1 and batch_idx = N_BATCHES - 1 then
                                        event_last_r <= '1';
                                    else
                                        event_last_r <= '0';
                                    end if;
                                    event_chunk_id_r <= active_chunk_id;
                                    event_score_r    <= active_score;
                                else
                                    state <= IDLE;
                                end if;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;

    RB_RD_EN        <= rb_rd_en_r;
    RB_RD_CHUNK_ID  <= rb_rd_chunk_id_r;
    RB_RD_BATCH_IDX <= rb_rd_batch_idx_r;
    EVENT_VALID     <= event_valid_r;
    EVENT_DATA      <= event_data_r;
    EVENT_LAST      <= event_last_r;
    EVENT_CHUNK_ID  <= event_chunk_id_r;
    EVENT_SCORE     <= event_score_r;
end architecture rtl;
