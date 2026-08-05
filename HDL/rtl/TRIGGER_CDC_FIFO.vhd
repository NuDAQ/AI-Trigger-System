library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity TRIGGER_CDC_FIFO is
    port (
        WR_CLK      : in  std_logic;
        WR_RST      : in  std_logic;
        WR_VALID    : in  std_logic;
        WR_READY    : out std_logic;
        WR_BUSY     : out std_logic;
        WR_CHUNK_ID : in  chunk_id_t;
        WR_SCORE    : in  std_logic_vector(31 downto 0);
        WR_TIMESTAMP : in  timestamp_t;
        WR_START_OFFSET : in beat_offset_t;
        WR_TRIGGER_OFFSET : in beat_offset_t;

        RD_CLK      : in  std_logic;
        RD_RST      : in  std_logic;
        RD_VALID    : out std_logic;
        RD_READY    : in  std_logic;
        RD_CHUNK_ID : out chunk_id_t;
        RD_SCORE    : out std_logic_vector(31 downto 0);
        RD_TIMESTAMP : out timestamp_t;
        RD_START_OFFSET : out beat_offset_t;
        RD_TRIGGER_OFFSET : out beat_offset_t
    );
end entity TRIGGER_CDC_FIFO;

architecture rtl of TRIGGER_CDC_FIFO is
    constant TIMESTAMP_LSB : integer := CHUNK_ID_WIDTH + 32;
    constant START_OFFSET_LSB : integer := TIMESTAMP_LSB + TIMESTAMP_WIDTH;
    constant TRIGGER_OFFSET_LSB : integer := START_OFFSET_LSB + BEAT_OFFSET_WIDTH;
    constant META_WIDTH : integer := TRIGGER_OFFSET_LSB + BEAT_OFFSET_WIDTH;
    subtype meta_t is std_logic_vector(META_WIDTH - 1 downto 0);
    type meta_queue_t is array (0 to TRIGGER_FIFO_DEPTH - 1) of meta_t;

    signal wr_queue   : meta_queue_t := (others => (others => '0'));
    signal wr_head    : integer range 0 to TRIGGER_FIFO_DEPTH - 1 := 0;
    signal wr_tail    : integer range 0 to TRIGGER_FIFO_DEPTH - 1 := 0;
    signal wr_count   : integer range 0 to TRIGGER_FIFO_DEPTH := 0;

    signal src_data    : meta_t := (others => '0');
    signal src_send    : std_logic := '0';
    signal src_rcv     : std_logic;
    signal src_pending : std_logic := '0';
    signal src_wait_rcv_low : std_logic := '0';

    signal dest_data : meta_t;
    signal dest_req  : std_logic;
    signal dest_ack  : std_logic;
    signal dest_ack_r : std_logic := '0';
    signal dest_seen_r : std_logic := '0';

    function inc_idx(i : integer) return integer is
    begin
        if i = TRIGGER_FIFO_DEPTH - 1 then
            return 0;
        end if;
        return i + 1;
    end function;

    function pack_meta(
        chunk_id  : chunk_id_t;
        score     : std_logic_vector(31 downto 0);
        timestamp : timestamp_t;
        start_offset : beat_offset_t;
        trigger_offset : beat_offset_t
    ) return meta_t is
        variable ret : meta_t := (others => '0');
    begin
        ret(CHUNK_ID_WIDTH - 1 downto 0) := std_logic_vector(chunk_id);
        ret(CHUNK_ID_WIDTH + 31 downto CHUNK_ID_WIDTH) := score;
        ret(START_OFFSET_LSB - 1 downto TIMESTAMP_LSB) := std_logic_vector(timestamp);
        ret(TRIGGER_OFFSET_LSB - 1 downto START_OFFSET_LSB) :=
            std_logic_vector(start_offset);
        ret(META_WIDTH - 1 downto TRIGGER_OFFSET_LSB) :=
            std_logic_vector(trigger_offset);
        return ret;
    end function;
begin
    process(WR_CLK)
        variable head_v     : integer range 0 to TRIGGER_FIFO_DEPTH - 1;
        variable tail_v     : integer range 0 to TRIGGER_FIFO_DEPTH - 1;
        variable count_v    : integer range 0 to TRIGGER_FIFO_DEPTH;
        variable pending_v  : std_logic;
        variable wait_low_v : std_logic;
        variable data_v     : meta_t;
        variable enqueue_v  : std_logic;
        variable enqueue_data_v : meta_t;
    begin
        if rising_edge(WR_CLK) then
            if WR_RST = '1' then
                wr_head     <= 0;
                wr_tail     <= 0;
                wr_count    <= 0;
                src_data    <= (others => '0');
                src_send    <= '0';
                src_pending <= '0';
                src_wait_rcv_low <= '0';
            else
                head_v    := wr_head;
                tail_v    := wr_tail;
                count_v   := wr_count;
                pending_v := src_pending;
                wait_low_v := src_wait_rcv_low;
                data_v    := src_data;
                enqueue_v := '0';
                enqueue_data_v := pack_meta(
                    WR_CHUNK_ID,
                    WR_SCORE,
                    WR_TIMESTAMP,
                    WR_START_OFFSET,
                    WR_TRIGGER_OFFSET
                );

                if wait_low_v = '1' and src_rcv = '0' then
                    wait_low_v := '0';
                end if;

                if src_pending = '1' and src_rcv = '1' then
                    pending_v := '0';
                    wait_low_v := '1';
                    src_send  <= '0';
                    if count_v > 0 then
                        head_v  := inc_idx(head_v);
                        count_v := count_v - 1;
                    end if;
                end if;

                if WR_VALID = '1' and count_v < TRIGGER_FIFO_DEPTH then
                    wr_queue(tail_v) <= enqueue_data_v;
                    tail_v    := inc_idx(tail_v);
                    count_v   := count_v + 1;
                    enqueue_v := '1';
                end if;

                if pending_v = '0' and wait_low_v = '0' and count_v > 0 then
                    if enqueue_v = '1' and count_v = 1 then
                        data_v := enqueue_data_v;
                    else
                        data_v := wr_queue(head_v);
                    end if;
                    pending_v := '1';
                    src_send  <= '1';
                else
                    src_send <= pending_v;
                end if;

                wr_head     <= head_v;
                wr_tail     <= tail_v;
                wr_count    <= count_v;
                src_data    <= data_v;
                src_pending <= pending_v;
                src_wait_rcv_low <= wait_low_v;
            end if;
        end if;
    end process;

    u_TRIGGER_CDC : xpm_cdc_handshake
        generic map (
            DEST_EXT_HSK   => 1,
            DEST_SYNC_FF   => 2,
            INIT_SYNC_FF   => 0,
            SIM_ASSERT_CHK => 0,
            SRC_SYNC_FF    => 2,
            WIDTH          => META_WIDTH
        )
        port map (
            src_clk  => WR_CLK,
            src_in   => src_data,
            src_send => src_send,
            src_rcv  => src_rcv,
            dest_clk => RD_CLK,
            dest_out => dest_data,
            dest_req => dest_req,
            dest_ack => dest_ack
        );

    process(RD_CLK)
    begin
        if rising_edge(RD_CLK) then
            if RD_RST = '1' then
                dest_ack_r <= '0';
                dest_seen_r <= '0';
            else
                if dest_req = '0' then
                    dest_ack_r <= '0';
                    dest_seen_r <= '0';
                elsif dest_seen_r = '0' and RD_READY = '1' then
                    dest_ack_r <= '1';
                    dest_seen_r <= '1';
                end if;
            end if;
        end if;
    end process;

    WR_READY     <= '1' when wr_count < TRIGGER_FIFO_DEPTH else '0';
    WR_BUSY      <= '1' when wr_count > 0 or src_pending = '1' or
                             src_wait_rcv_low = '1' else '0';
    RD_VALID     <= dest_req and not dest_seen_r when RD_RST = '0' else '0';
    dest_ack <= dest_ack_r;
    RD_CHUNK_ID  <= unsigned(dest_data(CHUNK_ID_WIDTH - 1 downto 0));
    RD_SCORE     <= dest_data(CHUNK_ID_WIDTH + 31 downto CHUNK_ID_WIDTH);
    RD_TIMESTAMP <= unsigned(dest_data(START_OFFSET_LSB - 1 downto TIMESTAMP_LSB));
    RD_START_OFFSET <= unsigned(dest_data(
        TRIGGER_OFFSET_LSB - 1 downto START_OFFSET_LSB));
    RD_TRIGGER_OFFSET <= unsigned(dest_data(
        META_WIDTH - 1 downto TRIGGER_OFFSET_LSB));
end architecture rtl;
