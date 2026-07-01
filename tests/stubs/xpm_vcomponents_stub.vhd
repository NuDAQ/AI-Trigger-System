library ieee;
use ieee.std_logic_1164.all;

package vcomponents is
    component xpm_cdc_handshake
        generic (
            DEST_EXT_HSK   : integer := 1;
            DEST_SYNC_FF   : integer := 2;
            INIT_SYNC_FF   : integer := 0;
            SIM_ASSERT_CHK : integer := 0;
            SRC_SYNC_FF    : integer := 2;
            WIDTH          : integer := 1
        );
        port (
            src_clk  : in  std_logic;
            src_in   : in  std_logic_vector(WIDTH-1 downto 0);
            src_send : in  std_logic;
            src_rcv  : out std_logic;
            dest_clk : in  std_logic;
            dest_out : out std_logic_vector(WIDTH-1 downto 0);
            dest_req : out std_logic;
            dest_ack : in  std_logic
        );
    end component;

    component xpm_fifo_sync
        generic (
            DOUT_RESET_VALUE    : string  := "0";
            ECC_MODE            : string  := "no_ecc";
            FIFO_MEMORY_TYPE    : string  := "auto";
            FIFO_READ_LATENCY   : integer := 0;
            FIFO_WRITE_DEPTH    : integer := 16;
            FULL_RESET_VALUE    : integer := 0;
            PROG_EMPTY_THRESH   : integer := 10;
            PROG_FULL_THRESH    : integer := 10;
            RD_DATA_COUNT_WIDTH : integer := 1;
            READ_DATA_WIDTH     : integer := 1;
            READ_MODE           : string  := "fwft";
            USE_ADV_FEATURES    : string  := "0000";
            WAKEUP_TIME         : integer := 0;
            WRITE_DATA_WIDTH    : integer := 1;
            WR_DATA_COUNT_WIDTH : integer := 1
        );
        port (
            sleep         : in  std_logic;
            rst           : in  std_logic;
            wr_clk        : in  std_logic;
            wr_en         : in  std_logic;
            din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
            full          : out std_logic;
            overflow      : out std_logic;
            wr_rst_busy   : out std_logic;
            rd_en         : in  std_logic;
            dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
            empty         : out std_logic;
            underflow     : out std_logic;
            rd_rst_busy   : out std_logic;
            prog_full     : out std_logic;
            prog_empty    : out std_logic;
            data_valid    : out std_logic;
            wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
            rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
            injectsbiterr : in  std_logic;
            injectdbiterr : in  std_logic;
            sbiterr       : out std_logic;
            dbiterr       : out std_logic
        );
    end component;

    component xpm_fifo_async
        generic (
            CDC_SYNC_STAGES     : integer := 2;
            DOUT_RESET_VALUE    : string  := "0";
            ECC_MODE            : string  := "no_ecc";
            FIFO_MEMORY_TYPE    : string  := "auto";
            FIFO_READ_LATENCY   : integer := 0;
            FIFO_WRITE_DEPTH    : integer := 16;
            FULL_RESET_VALUE    : integer := 0;
            PROG_EMPTY_THRESH   : integer := 10;
            PROG_FULL_THRESH    : integer := 10;
            RD_DATA_COUNT_WIDTH : integer := 1;
            READ_DATA_WIDTH     : integer := 1;
            READ_MODE           : string  := "fwft";
            RELATED_CLOCKS      : integer := 0;
            USE_ADV_FEATURES    : string  := "0000";
            WAKEUP_TIME         : integer := 0;
            WRITE_DATA_WIDTH    : integer := 1;
            WR_DATA_COUNT_WIDTH : integer := 1
        );
        port (
            sleep         : in  std_logic;
            rst           : in  std_logic;
            wr_clk        : in  std_logic;
            wr_en         : in  std_logic;
            din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
            full          : out std_logic;
            overflow      : out std_logic;
            wr_rst_busy   : out std_logic;
            rd_clk        : in  std_logic;
            rd_en         : in  std_logic;
            dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
            empty         : out std_logic;
            underflow     : out std_logic;
            rd_rst_busy   : out std_logic;
            prog_full     : out std_logic;
            prog_empty    : out std_logic;
            data_valid    : out std_logic;
            wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
            rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
            injectsbiterr : in  std_logic;
            injectdbiterr : in  std_logic;
            sbiterr       : out std_logic;
            dbiterr       : out std_logic
        );
    end component;
end package vcomponents;

library ieee;
use ieee.std_logic_1164.all;

entity xpm_cdc_handshake is
    generic (
        DEST_EXT_HSK   : integer := 1;
        DEST_SYNC_FF   : integer := 2;
        INIT_SYNC_FF   : integer := 0;
        SIM_ASSERT_CHK : integer := 0;
        SRC_SYNC_FF    : integer := 2;
        WIDTH          : integer := 1
    );
    port (
        src_clk  : in  std_logic;
        src_in   : in  std_logic_vector(WIDTH-1 downto 0);
        src_send : in  std_logic;
        src_rcv  : out std_logic;
        dest_clk : in  std_logic;
        dest_out : out std_logic_vector(WIDTH-1 downto 0);
        dest_req : out std_logic;
        dest_ack : in  std_logic
    );
end entity xpm_cdc_handshake;

architecture sim of xpm_cdc_handshake is
    constant DEST_REQ_HOLD_AFTER_ACK : integer := 4;
    constant SRC_RCV_HOLD_AFTER_ACK  : integer := 3;
    signal src_payload      : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
    signal req_toggle_src   : std_logic := '0';
    signal ack_toggle_dest  : std_logic := '0';
    signal ack_sync_src     : std_logic_vector(1 downto 0) := (others => '0');
    signal req_sync_dest    : std_logic_vector(1 downto 0) := (others => '0');
    signal dest_req_r       : std_logic := '0';
    signal dest_out_r       : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
    signal dest_drop_count  : integer range 0 to DEST_REQ_HOLD_AFTER_ACK := 0;
    signal dest_ack_seen    : std_logic := '0';
    signal src_rcv_r        : std_logic := '0';
    signal src_rcv_count    : integer range 0 to SRC_RCV_HOLD_AFTER_ACK := 0;
    signal src_busy         : std_logic := '0';
    signal src_send_armed   : std_logic := '1';
begin
    process(src_clk)
    begin
        if rising_edge(src_clk) then
            ack_sync_src <= ack_sync_src(0) & ack_toggle_dest;
            if src_send = '0' then
                src_send_armed <= '1';
            end if;

            if src_send = '1'
                    and src_send_armed = '1'
                    and src_busy = '0'
                    and req_toggle_src = ack_sync_src(1) then
                src_payload    <= src_in;
                req_toggle_src <= not req_toggle_src;
                src_busy       <= '1';
                src_send_armed <= '0';
            end if;

            if src_busy = '1' and req_toggle_src = ack_sync_src(1) then
                src_rcv_r <= '1';
                src_rcv_count <= SRC_RCV_HOLD_AFTER_ACK;
                src_busy <= '0';
            elsif src_rcv_count > 0 then
                src_rcv_r <= '1';
                src_rcv_count <= src_rcv_count - 1;
            else
                src_rcv_r <= '0';
            end if;
        end if;
    end process;

    process(dest_clk)
    begin
        if rising_edge(dest_clk) then
            req_sync_dest <= req_sync_dest(0) & req_toggle_src;

            if dest_req_r = '0' and req_sync_dest(1) /= ack_toggle_dest then
                dest_out_r <= src_payload;
                dest_drop_count <= 0;
                dest_ack_seen <= '0';
                if DEST_EXT_HSK = 0 then
                    ack_toggle_dest <= req_sync_dest(1);
                    dest_req_r      <= '1';
                else
                    dest_req_r      <= '1';
                end if;
            elsif dest_req_r = '1' then
                if DEST_EXT_HSK = 0 then
                    dest_req_r <= '0';
                elsif dest_ack_seen = '1' then
                    if dest_ack = '0' then
                        dest_drop_count <= 0;
                    elsif dest_drop_count = DEST_REQ_HOLD_AFTER_ACK then
                        ack_toggle_dest <= req_sync_dest(1);
                        dest_req_r <= '0';
                        dest_drop_count <= 0;
                        dest_ack_seen <= '0';
                    else
                        dest_drop_count <= dest_drop_count + 1;
                    end if;
                elsif dest_ack = '1' then
                    dest_drop_count <= 0;
                    dest_ack_seen <= '1';
                end if;
            end if;
        end if;
    end process;

    src_rcv  <= src_rcv_r;
    dest_req <= dest_req_r;
    dest_out <= dest_out_r;
end architecture sim;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xpm_fifo_async is
    generic (
        CDC_SYNC_STAGES     : integer := 2;
        DOUT_RESET_VALUE    : string  := "0";
        ECC_MODE            : string  := "no_ecc";
        FIFO_MEMORY_TYPE    : string  := "auto";
        FIFO_READ_LATENCY   : integer := 0;
        FIFO_WRITE_DEPTH    : integer := 16;
        FULL_RESET_VALUE    : integer := 0;
        PROG_EMPTY_THRESH   : integer := 10;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 1;
        READ_DATA_WIDTH     : integer := 1;
        READ_MODE           : string  := "fwft";
        RELATED_CLOCKS      : integer := 0;
        USE_ADV_FEATURES    : string  := "0000";
        WAKEUP_TIME         : integer := 0;
        WRITE_DATA_WIDTH    : integer := 1;
        WR_DATA_COUNT_WIDTH : integer := 1
    );
    port (
        sleep         : in  std_logic;
        rst           : in  std_logic;
        wr_clk        : in  std_logic;
        wr_en         : in  std_logic;
        din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
        full          : out std_logic;
        overflow      : out std_logic;
        wr_rst_busy   : out std_logic;
        rd_clk        : in  std_logic;
        rd_en         : in  std_logic;
        dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
        empty         : out std_logic;
        underflow     : out std_logic;
        rd_rst_busy   : out std_logic;
        prog_full     : out std_logic;
        prog_empty    : out std_logic;
        data_valid    : out std_logic;
        wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
        rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
        injectsbiterr : in  std_logic;
        injectdbiterr : in  std_logic;
        sbiterr       : out std_logic;
        dbiterr       : out std_logic
    );
end entity xpm_fifo_async;

architecture sim of xpm_fifo_async is
    type mem_t is array (0 to FIFO_WRITE_DEPTH - 1) of std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
    signal mem : mem_t := (others => (others => '0'));
    signal wr_ptr : integer range 0 to FIFO_WRITE_DEPTH - 1 := 0;
    signal rd_ptr : integer range 0 to FIFO_WRITE_DEPTH - 1 := 0;
    signal count  : integer range 0 to FIFO_WRITE_DEPTH := 0;
    signal dout_r : std_logic_vector(READ_DATA_WIDTH-1 downto 0) := (others => '0');

    function inc_idx(i : integer) return integer is
    begin
        if i = FIFO_WRITE_DEPTH - 1 then
            return 0;
        end if;
        return i + 1;
    end function;

    function slv_count(value : integer; width : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(value, width));
    end function;
begin
    assert READ_MODE = "fwft"
        report "xpm_fifo_async stub currently models READ_MODE=fwft only"
        severity failure;
    assert READ_DATA_WIDTH = WRITE_DATA_WIDTH
        report "xpm_fifo_async stub currently models symmetric widths only"
        severity failure;

    process(wr_clk, rd_clk, rst)
        variable push_v : boolean;
        variable pop_v  : boolean;
        variable wr_ptr_v : integer range 0 to FIFO_WRITE_DEPTH - 1;
        variable rd_ptr_v : integer range 0 to FIFO_WRITE_DEPTH - 1;
        variable count_v  : integer range 0 to FIFO_WRITE_DEPTH;
    begin
        if rst = '1' then
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
            dout_r <= (others => '0');
        elsif sleep = '0' and (rising_edge(wr_clk) or rising_edge(rd_clk)) then
            push_v := wr_en = '1' and count < FIFO_WRITE_DEPTH and rising_edge(wr_clk);
            pop_v  := rd_en = '1' and count > 0 and rising_edge(rd_clk);
            wr_ptr_v := wr_ptr;
            rd_ptr_v := rd_ptr;
            count_v  := count;

            if push_v then
                mem(wr_ptr) <= din;
                wr_ptr_v := inc_idx(wr_ptr);
            end if;

            if pop_v then
                rd_ptr_v := inc_idx(rd_ptr);
            end if;

            if push_v and not pop_v then
                count_v := count + 1;
            elsif pop_v and not push_v then
                count_v := count - 1;
            end if;

            wr_ptr <= wr_ptr_v;
            rd_ptr <= rd_ptr_v;
            count  <= count_v;

            if push_v and (count = 0 or (pop_v and count = 1)) then
                dout_r <= din;
            elsif count_v > 0 then
                dout_r <= mem(rd_ptr_v);
            else
                dout_r <= (others => '0');
            end if;
        end if;
    end process;

    full          <= '1' when count = FIFO_WRITE_DEPTH else '0';
    empty         <= '1' when count = 0 else '0';
    prog_full     <= '1' when count >= PROG_FULL_THRESH else '0';
    prog_empty    <= '1' when count <= PROG_EMPTY_THRESH else '0';
    overflow      <= '1' when wr_en = '1' and count = FIFO_WRITE_DEPTH else '0';
    underflow     <= '1' when rd_en = '1' and count = 0 else '0';
    wr_rst_busy   <= rst;
    rd_rst_busy   <= rst;
    data_valid    <= '1' when count > 0 else '0';
    wr_data_count <= slv_count(count, WR_DATA_COUNT_WIDTH);
    rd_data_count <= slv_count(count, RD_DATA_COUNT_WIDTH);
    dout          <= dout_r;
    sbiterr       <= '0';
    dbiterr       <= '0';
end architecture sim;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xpm_fifo_sync is
    generic (
        DOUT_RESET_VALUE    : string  := "0";
        ECC_MODE            : string  := "no_ecc";
        FIFO_MEMORY_TYPE    : string  := "auto";
        FIFO_READ_LATENCY   : integer := 0;
        FIFO_WRITE_DEPTH    : integer := 16;
        FULL_RESET_VALUE    : integer := 0;
        PROG_EMPTY_THRESH   : integer := 10;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 1;
        READ_DATA_WIDTH     : integer := 1;
        READ_MODE           : string  := "fwft";
        USE_ADV_FEATURES    : string  := "0000";
        WAKEUP_TIME         : integer := 0;
        WRITE_DATA_WIDTH    : integer := 1;
        WR_DATA_COUNT_WIDTH : integer := 1
    );
    port (
        sleep         : in  std_logic;
        rst           : in  std_logic;
        wr_clk        : in  std_logic;
        wr_en         : in  std_logic;
        din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
        full          : out std_logic;
        overflow      : out std_logic;
        wr_rst_busy   : out std_logic;
        rd_en         : in  std_logic;
        dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
        empty         : out std_logic;
        underflow     : out std_logic;
        rd_rst_busy   : out std_logic;
        prog_full     : out std_logic;
        prog_empty    : out std_logic;
        data_valid    : out std_logic;
        wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
        rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
        injectsbiterr : in  std_logic;
        injectdbiterr : in  std_logic;
        sbiterr       : out std_logic;
        dbiterr       : out std_logic
    );
end entity xpm_fifo_sync;

architecture sim of xpm_fifo_sync is
    type mem_t is array (0 to FIFO_WRITE_DEPTH - 1) of std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
    signal mem : mem_t := (others => (others => '0'));
    signal wr_ptr : integer range 0 to FIFO_WRITE_DEPTH - 1 := 0;
    signal rd_ptr : integer range 0 to FIFO_WRITE_DEPTH - 1 := 0;
    signal count  : integer range 0 to FIFO_WRITE_DEPTH := 0;
    signal dout_r : std_logic_vector(READ_DATA_WIDTH-1 downto 0) := (others => '0');

    function inc_idx(i : integer) return integer is
    begin
        if i = FIFO_WRITE_DEPTH - 1 then
            return 0;
        end if;
        return i + 1;
    end function;

    function slv_count(value : integer; width : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(value, width));
    end function;
begin
    assert READ_MODE = "fwft"
        report "xpm_fifo_sync stub currently models READ_MODE=fwft only"
        severity failure;
    assert READ_DATA_WIDTH = WRITE_DATA_WIDTH
        report "xpm_fifo_sync stub currently models symmetric widths only"
        severity failure;

    process(wr_clk)
        variable push_v : boolean;
        variable pop_v  : boolean;
        variable wr_ptr_v : integer range 0 to FIFO_WRITE_DEPTH - 1;
        variable rd_ptr_v : integer range 0 to FIFO_WRITE_DEPTH - 1;
        variable count_v  : integer range 0 to FIFO_WRITE_DEPTH;
    begin
        if rising_edge(wr_clk) then
            if rst = '1' then
                wr_ptr <= 0;
                rd_ptr <= 0;
                count  <= 0;
                dout_r <= (others => '0');
            elsif sleep = '0' then
                push_v := wr_en = '1' and count < FIFO_WRITE_DEPTH;
                pop_v  := rd_en = '1' and count > 0;
                wr_ptr_v := wr_ptr;
                rd_ptr_v := rd_ptr;
                count_v  := count;

                if push_v then
                    mem(wr_ptr) <= din;
                    wr_ptr_v := inc_idx(wr_ptr);
                end if;

                if pop_v then
                    rd_ptr_v := inc_idx(rd_ptr);
                end if;

                if push_v and not pop_v then
                    count_v := count + 1;
                elsif pop_v and not push_v then
                    count_v := count - 1;
                end if;

                wr_ptr <= wr_ptr_v;
                rd_ptr <= rd_ptr_v;
                count  <= count_v;

                if push_v and (count = 0 or (pop_v and count = 1)) then
                    dout_r <= din;
                elsif count_v > 0 then
                    dout_r <= mem(rd_ptr_v);
                else
                    dout_r <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    full          <= '1' when count = FIFO_WRITE_DEPTH else '0';
    empty         <= '1' when count = 0 else '0';
    prog_full     <= '1' when count >= PROG_FULL_THRESH else '0';
    prog_empty    <= '1' when count <= PROG_EMPTY_THRESH else '0';
    overflow      <= '1' when wr_en = '1' and count = FIFO_WRITE_DEPTH else '0';
    underflow     <= '1' when rd_en = '1' and count = 0 else '0';
    wr_rst_busy   <= rst;
    rd_rst_busy   <= rst;
    data_valid    <= '1' when count > 0 else '0';
    wr_data_count <= slv_count(count, WR_DATA_COUNT_WIDTH);
    rd_data_count <= slv_count(count, RD_DATA_COUNT_WIDTH);
    dout          <= dout_r;
    sbiterr       <= '0';
    dbiterr       <= '0';
end architecture sim;
