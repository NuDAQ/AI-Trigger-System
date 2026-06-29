library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity CHUNK_ID_CDC_FIFO is
    port (
        WR_CLK      : in  std_logic;
        WR_RST      : in  std_logic;
        WR_VALID    : in  std_logic;
        WR_READY    : out std_logic;
        WR_CHUNK_ID : in  chunk_id_t;

        RD_CLK      : in  std_logic;
        RD_RST      : in  std_logic;
        RD_VALID    : out std_logic;
        RD_READY    : in  std_logic;
        RD_CHUNK_ID : out chunk_id_t
    );
end entity CHUNK_ID_CDC_FIFO;

architecture rtl of CHUNK_ID_CDC_FIFO is
    constant PTR_WIDTH : integer := CHUNK_ID_FIFO_ADDR_WIDTH + 1;
    subtype ptr_t is unsigned(PTR_WIDTH - 1 downto 0);

    type mem_t is array (0 to CHUNK_ID_FIFO_DEPTH - 1) of chunk_id_t;
    signal mem : mem_t := (others => (others => '0'));

    signal wr_bin  : ptr_t := (others => '0');
    signal wr_gray : std_logic_vector(PTR_WIDTH - 1 downto 0) := (others => '0');
    signal rd_bin  : ptr_t := (others => '0');
    signal rd_gray : std_logic_vector(PTR_WIDTH - 1 downto 0) := (others => '0');

    signal rd_gray_wr_ff : std_logic_vector(PTR_WIDTH * 2 - 1 downto 0) := (others => '0');
    signal wr_gray_rd_ff : std_logic_vector(PTR_WIDTH * 2 - 1 downto 0) := (others => '0');

    signal full_r  : std_logic := '0';
    signal empty_r : std_logic := '1';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of rd_gray_wr_ff : signal is "TRUE";
    attribute ASYNC_REG of wr_gray_rd_ff : signal is "TRUE";

    function bin_to_gray(b : ptr_t) return std_logic_vector is
        variable shifted : ptr_t := (others => '0');
        variable g : ptr_t;
    begin
        shifted(PTR_WIDTH - 2 downto 0) := b(PTR_WIDTH - 1 downto 1);
        g := b xor shifted;
        return std_logic_vector(g);
    end function;

    function next_full(wr_next_gray : std_logic_vector(PTR_WIDTH - 1 downto 0);
                       rd_sync_gray : std_logic_vector(PTR_WIDTH - 1 downto 0))
        return std_logic is
    begin
        if wr_next_gray(PTR_WIDTH - 1 downto PTR_WIDTH - 2) =
           not rd_sync_gray(PTR_WIDTH - 1 downto PTR_WIDTH - 2) and
           wr_next_gray(PTR_WIDTH - 3 downto 0) = rd_sync_gray(PTR_WIDTH - 3 downto 0) then
            return '1';
        end if;
        return '0';
    end function;

    function addr(p : ptr_t) return integer is
    begin
        return to_integer(p(CHUNK_ID_FIFO_ADDR_WIDTH - 1 downto 0));
    end function;
begin
    process(WR_CLK)
        variable wr_next_bin  : ptr_t;
        variable wr_next_gray : std_logic_vector(PTR_WIDTH - 1 downto 0);
        variable rd_sync_gray : std_logic_vector(PTR_WIDTH - 1 downto 0);
    begin
        if rising_edge(WR_CLK) then
            if WR_RST = '1' then
                wr_bin        <= (others => '0');
                wr_gray       <= (others => '0');
                rd_gray_wr_ff <= (others => '0');
                full_r        <= '0';
            else
                rd_gray_wr_ff(PTR_WIDTH - 1 downto 0) <= rd_gray;
                rd_gray_wr_ff(PTR_WIDTH * 2 - 1 downto PTR_WIDTH) <=
                    rd_gray_wr_ff(PTR_WIDTH - 1 downto 0);
                rd_sync_gray := rd_gray_wr_ff(PTR_WIDTH * 2 - 1 downto PTR_WIDTH);

                wr_next_bin := wr_bin;
                if WR_VALID = '1' and full_r = '0' then
                    mem(addr(wr_bin)) <= WR_CHUNK_ID;
                    wr_next_bin := wr_bin + 1;
                end if;

                wr_next_gray := bin_to_gray(wr_next_bin);
                wr_bin       <= wr_next_bin;
                wr_gray      <= wr_next_gray;
                full_r       <= next_full(wr_next_gray, rd_sync_gray);
            end if;
        end if;
    end process;

    process(RD_CLK)
        variable rd_next_bin  : ptr_t;
        variable rd_next_gray : std_logic_vector(PTR_WIDTH - 1 downto 0);
        variable wr_sync_gray : std_logic_vector(PTR_WIDTH - 1 downto 0);
    begin
        if rising_edge(RD_CLK) then
            if RD_RST = '1' then
                rd_bin        <= (others => '0');
                rd_gray       <= (others => '0');
                wr_gray_rd_ff <= (others => '0');
                empty_r       <= '1';
            else
                wr_gray_rd_ff(PTR_WIDTH - 1 downto 0) <= wr_gray;
                wr_gray_rd_ff(PTR_WIDTH * 2 - 1 downto PTR_WIDTH) <=
                    wr_gray_rd_ff(PTR_WIDTH - 1 downto 0);
                wr_sync_gray := wr_gray_rd_ff(PTR_WIDTH * 2 - 1 downto PTR_WIDTH);

                rd_next_bin := rd_bin;
                if RD_READY = '1' and empty_r = '0' then
                    rd_next_bin := rd_bin + 1;
                end if;

                rd_next_gray := bin_to_gray(rd_next_bin);
                rd_bin       <= rd_next_bin;
                rd_gray      <= rd_next_gray;
                if rd_next_gray = wr_sync_gray then
                    empty_r <= '1';
                else
                    empty_r <= '0';
                end if;
            end if;
        end if;
    end process;

    WR_READY    <= not full_r;
    RD_VALID    <= not empty_r;
    RD_CHUNK_ID <= mem(addr(rd_bin));
end architecture rtl;
