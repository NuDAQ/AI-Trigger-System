-- Simulation-only functional models for the XPM primitives used by the RTL.
-- They intentionally model ready/valid behavior, not metastability or timing.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package vcomponents is
    component xpm_cdc_array_single is
        generic (
            DEST_SYNC_FF   : integer := 2;
            INIT_SYNC_FF   : integer := 0;
            SIM_ASSERT_CHK : integer := 0;
            SRC_INPUT_REG  : integer := 0;
            WIDTH          : integer := 1
        );
        port (
            src_clk  : in  std_logic;
            src_in   : in  std_logic_vector(WIDTH - 1 downto 0);
            dest_clk : in  std_logic;
            dest_out : out std_logic_vector(WIDTH - 1 downto 0)
        );
    end component;

    component xpm_cdc_handshake is
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
            src_in   : in  std_logic_vector(WIDTH - 1 downto 0);
            src_send : in  std_logic;
            src_rcv  : out std_logic;
            dest_clk : in  std_logic;
            dest_out : out std_logic_vector(WIDTH - 1 downto 0);
            dest_req : out std_logic;
            dest_ack : in  std_logic
        );
    end component;

    component xpm_fifo_async is
        generic (
            CDC_SYNC_STAGES     : integer := 2;
            DOUT_RESET_VALUE    : string := "0";
            ECC_MODE            : string := "no_ecc";
            FIFO_MEMORY_TYPE    : string := "auto";
            FIFO_READ_LATENCY   : integer := 0;
            FIFO_WRITE_DEPTH    : integer := 16;
            FULL_RESET_VALUE    : integer := 0;
            PROG_EMPTY_THRESH   : integer := 10;
            PROG_FULL_THRESH    : integer := 10;
            RD_DATA_COUNT_WIDTH : integer := 1;
            READ_DATA_WIDTH     : integer := 1;
            READ_MODE           : string := "fwft";
            RELATED_CLOCKS      : integer := 0;
            USE_ADV_FEATURES    : string := "0000";
            WAKEUP_TIME         : integer := 0;
            WRITE_DATA_WIDTH    : integer := 1;
            WR_DATA_COUNT_WIDTH : integer := 1
        );
        port (
            sleep         : in  std_logic;
            rst           : in  std_logic;
            wr_clk        : in  std_logic;
            wr_en         : in  std_logic;
            din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
            full          : out std_logic;
            overflow      : out std_logic;
            wr_rst_busy   : out std_logic;
            rd_clk        : in  std_logic;
            rd_en         : in  std_logic;
            dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
            empty         : out std_logic;
            underflow     : out std_logic;
            rd_rst_busy   : out std_logic;
            prog_full     : out std_logic;
            prog_empty    : out std_logic;
            data_valid    : out std_logic;
            wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH - 1 downto 0);
            rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH - 1 downto 0);
            injectsbiterr : in  std_logic;
            injectdbiterr : in  std_logic;
            sbiterr       : out std_logic;
            dbiterr       : out std_logic
        );
    end component;

    component xpm_fifo_sync is
        generic (
            DOUT_RESET_VALUE    : string := "0";
            ECC_MODE            : string := "no_ecc";
            FIFO_MEMORY_TYPE    : string := "auto";
            FIFO_READ_LATENCY   : integer := 0;
            FIFO_WRITE_DEPTH    : integer := 16;
            FULL_RESET_VALUE    : integer := 0;
            PROG_EMPTY_THRESH   : integer := 10;
            PROG_FULL_THRESH    : integer := 10;
            RD_DATA_COUNT_WIDTH : integer := 1;
            READ_DATA_WIDTH     : integer := 1;
            READ_MODE           : string := "fwft";
            USE_ADV_FEATURES    : string := "0000";
            WAKEUP_TIME         : integer := 0;
            WRITE_DATA_WIDTH    : integer := 1;
            WR_DATA_COUNT_WIDTH : integer := 1
        );
        port (
            sleep         : in  std_logic;
            rst           : in  std_logic;
            wr_clk        : in  std_logic;
            wr_en         : in  std_logic;
            din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
            full          : out std_logic;
            overflow      : out std_logic;
            wr_rst_busy   : out std_logic;
            rd_en         : in  std_logic;
            dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
            empty         : out std_logic;
            underflow     : out std_logic;
            rd_rst_busy   : out std_logic;
            prog_full     : out std_logic;
            prog_empty    : out std_logic;
            data_valid    : out std_logic;
            wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH - 1 downto 0);
            rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH - 1 downto 0);
            injectsbiterr : in  std_logic;
            injectdbiterr : in  std_logic;
            sbiterr       : out std_logic;
            dbiterr       : out std_logic
        );
    end component;
end package vcomponents;

library ieee;
use ieee.std_logic_1164.all;

entity xpm_cdc_array_single is
    generic (
        DEST_SYNC_FF   : integer := 2;
        INIT_SYNC_FF   : integer := 0;
        SIM_ASSERT_CHK : integer := 0;
        SRC_INPUT_REG  : integer := 0;
        WIDTH          : integer := 1
    );
    port (
        src_clk  : in  std_logic;
        src_in   : in  std_logic_vector(WIDTH - 1 downto 0);
        dest_clk : in  std_logic;
        dest_out : out std_logic_vector(WIDTH - 1 downto 0)
    );
end entity xpm_cdc_array_single;

architecture functional of xpm_cdc_array_single is
begin
    dest_out <= src_in;
end architecture functional;

library ieee;
use ieee.std_logic_1164.all;
use work.vcomponents.all;

entity xpm_fifo_sync is
    generic (
        DOUT_RESET_VALUE    : string := "0";
        ECC_MODE            : string := "no_ecc";
        FIFO_MEMORY_TYPE    : string := "auto";
        FIFO_READ_LATENCY   : integer := 0;
        FIFO_WRITE_DEPTH    : integer := 16;
        FULL_RESET_VALUE    : integer := 0;
        PROG_EMPTY_THRESH   : integer := 10;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 1;
        READ_DATA_WIDTH     : integer := 1;
        READ_MODE           : string := "fwft";
        USE_ADV_FEATURES    : string := "0000";
        WAKEUP_TIME         : integer := 0;
        WRITE_DATA_WIDTH    : integer := 1;
        WR_DATA_COUNT_WIDTH : integer := 1
    );
    port (
        sleep         : in  std_logic;
        rst           : in  std_logic;
        wr_clk        : in  std_logic;
        wr_en         : in  std_logic;
        din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
        full          : out std_logic;
        overflow      : out std_logic;
        wr_rst_busy   : out std_logic;
        rd_en         : in  std_logic;
        dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
        empty         : out std_logic;
        underflow     : out std_logic;
        rd_rst_busy   : out std_logic;
        prog_full     : out std_logic;
        prog_empty    : out std_logic;
        data_valid    : out std_logic;
        wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH - 1 downto 0);
        rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH - 1 downto 0);
        injectsbiterr : in  std_logic;
        injectdbiterr : in  std_logic;
        sbiterr       : out std_logic;
        dbiterr       : out std_logic
    );
end entity xpm_fifo_sync;

architecture functional of xpm_fifo_sync is
begin
    u_model : xpm_fifo_async
        generic map (
            DOUT_RESET_VALUE    => DOUT_RESET_VALUE,
            ECC_MODE            => ECC_MODE,
            FIFO_MEMORY_TYPE    => FIFO_MEMORY_TYPE,
            FIFO_READ_LATENCY   => FIFO_READ_LATENCY,
            FIFO_WRITE_DEPTH    => FIFO_WRITE_DEPTH,
            FULL_RESET_VALUE    => FULL_RESET_VALUE,
            PROG_EMPTY_THRESH   => PROG_EMPTY_THRESH,
            PROG_FULL_THRESH    => PROG_FULL_THRESH,
            RD_DATA_COUNT_WIDTH => RD_DATA_COUNT_WIDTH,
            READ_DATA_WIDTH     => READ_DATA_WIDTH,
            READ_MODE           => READ_MODE,
            USE_ADV_FEATURES    => USE_ADV_FEATURES,
            WAKEUP_TIME         => WAKEUP_TIME,
            WRITE_DATA_WIDTH    => WRITE_DATA_WIDTH,
            WR_DATA_COUNT_WIDTH => WR_DATA_COUNT_WIDTH
        )
        port map (
            sleep         => sleep,
            rst           => rst,
            wr_clk        => wr_clk,
            wr_en         => wr_en,
            din           => din,
            full          => full,
            overflow      => overflow,
            wr_rst_busy   => wr_rst_busy,
            rd_clk        => wr_clk,
            rd_en         => rd_en,
            dout          => dout,
            empty         => empty,
            underflow     => underflow,
            rd_rst_busy   => rd_rst_busy,
            prog_full     => prog_full,
            prog_empty    => prog_empty,
            data_valid    => data_valid,
            wr_data_count => wr_data_count,
            rd_data_count => rd_data_count,
            injectsbiterr => injectsbiterr,
            injectdbiterr => injectdbiterr,
            sbiterr       => sbiterr,
            dbiterr       => dbiterr
        );
end architecture functional;

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
        src_in   : in  std_logic_vector(WIDTH - 1 downto 0);
        src_send : in  std_logic;
        src_rcv  : out std_logic;
        dest_clk : in  std_logic;
        dest_out : out std_logic_vector(WIDTH - 1 downto 0);
        dest_req : out std_logic;
        dest_ack : in  std_logic
    );
end entity xpm_cdc_handshake;

architecture functional of xpm_cdc_handshake is
begin
    dest_out <= src_in;
    dest_req <= src_send;
    src_rcv  <= dest_ack when DEST_EXT_HSK /= 0 else src_send;
end architecture functional;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xpm_fifo_async is
    generic (
        CDC_SYNC_STAGES     : integer := 2;
        DOUT_RESET_VALUE    : string := "0";
        ECC_MODE            : string := "no_ecc";
        FIFO_MEMORY_TYPE    : string := "auto";
        FIFO_READ_LATENCY   : integer := 0;
        FIFO_WRITE_DEPTH    : integer := 16;
        FULL_RESET_VALUE    : integer := 0;
        PROG_EMPTY_THRESH   : integer := 10;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 1;
        READ_DATA_WIDTH     : integer := 1;
        READ_MODE           : string := "fwft";
        RELATED_CLOCKS      : integer := 0;
        USE_ADV_FEATURES    : string := "0000";
        WAKEUP_TIME         : integer := 0;
        WRITE_DATA_WIDTH    : integer := 1;
        WR_DATA_COUNT_WIDTH : integer := 1
    );
    port (
        sleep         : in  std_logic;
        rst           : in  std_logic;
        wr_clk        : in  std_logic;
        wr_en         : in  std_logic;
        din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
        full          : out std_logic;
        overflow      : out std_logic;
        wr_rst_busy   : out std_logic;
        rd_clk        : in  std_logic;
        rd_en         : in  std_logic;
        dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
        empty         : out std_logic;
        underflow     : out std_logic;
        rd_rst_busy   : out std_logic;
        prog_full     : out std_logic;
        prog_empty    : out std_logic;
        data_valid    : out std_logic;
        wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH - 1 downto 0);
        rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH - 1 downto 0);
        injectsbiterr : in  std_logic;
        injectdbiterr : in  std_logic;
        sbiterr       : out std_logic;
        dbiterr       : out std_logic
    );
end entity xpm_fifo_async;

architecture functional of xpm_fifo_async is
    constant READS_PER_WRITE : positive := WRITE_DATA_WIDTH / READ_DATA_WIDTH;
    constant READ_CAPACITY   : positive := FIFO_WRITE_DEPTH * READS_PER_WRITE;
    type memory_t is array (0 to READ_CAPACITY - 1) of
        std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
    signal memory_r : memory_t := (others => (others => '0'));
    signal head_r   : integer range 0 to READ_CAPACITY - 1 := 0;
    signal tail_r   : integer range 0 to READ_CAPACITY - 1 := 0;
    signal count_r  : integer range 0 to READ_CAPACITY := 0;

    function advance(index_value : integer; amount : natural) return integer is
    begin
        return (index_value + amount) mod READ_CAPACITY;
    end function;
begin
    assert WRITE_DATA_WIDTH mod READ_DATA_WIDTH = 0
        report "xpm_fifo_async test model requires integral width conversion"
        severity failure;
    assert READ_MODE = "fwft"
        report "xpm_fifo_async test model only supports FWFT mode"
        severity failure;

    process (wr_clk, rd_clk, rst)
        variable head_v  : integer range 0 to READ_CAPACITY - 1;
        variable tail_v  : integer range 0 to READ_CAPACITY - 1;
        variable count_v : integer range 0 to READ_CAPACITY;
    begin
        if rst = '1' then
            head_r  <= 0;
            tail_r  <= 0;
            count_r <= 0;
        else
            head_v  := head_r;
            tail_v  := tail_r;
            count_v := count_r;

            if rising_edge(wr_clk) and wr_en = '1' and
               count_v <= READ_CAPACITY - READS_PER_WRITE then
                for part_idx in 0 to READS_PER_WRITE - 1 loop
                    memory_r(advance(tail_v, part_idx)) <= din(
                        (part_idx + 1) * READ_DATA_WIDTH - 1 downto
                        part_idx * READ_DATA_WIDTH);
                end loop;
                tail_v  := advance(tail_v, READS_PER_WRITE);
                count_v := count_v + READS_PER_WRITE;
            end if;

            if rising_edge(rd_clk) and rd_en = '1' and count_v > 0 then
                head_v  := advance(head_v, 1);
                count_v := count_v - 1;
            end if;

            head_r  <= head_v;
            tail_r  <= tail_v;
            count_r <= count_v;
        end if;
    end process;

    dout       <= memory_r(head_r) when count_r > 0 else (others => '0');
    empty      <= '1' when count_r = 0 else '0';
    data_valid <= '1' when count_r > 0 else '0';
    full       <= '1' when count_r > READ_CAPACITY - READS_PER_WRITE else '0';
    overflow   <= '1' when wr_en = '1' and
                           count_r > READ_CAPACITY - READS_PER_WRITE else '0';
    underflow  <= '1' when rd_en = '1' and count_r = 0 else '0';
    prog_full  <= '1' when count_r >= PROG_FULL_THRESH * READS_PER_WRITE else '0';
    prog_empty <= '1' when count_r <= PROG_EMPTY_THRESH else '0';
    wr_rst_busy <= rst;
    rd_rst_busy <= rst;
    wr_data_count <= std_logic_vector(to_unsigned(
        count_r / READS_PER_WRITE, WR_DATA_COUNT_WIDTH));
    rd_data_count <= std_logic_vector(to_unsigned(count_r, RD_DATA_COUNT_WIDTH));
    sbiterr <= '0';
    dbiterr <= '0';
end architecture functional;
