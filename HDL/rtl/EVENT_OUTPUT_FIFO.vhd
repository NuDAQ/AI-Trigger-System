library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity EVENT_OUTPUT_FIFO is
    port (
        CLK              : in  std_logic;
        RST              : in  std_logic;

        WR_VALID         : in  std_logic;
        WR_READY         : out std_logic;
        WR_DATA          : in  raw_adc_batch_t;
        WR_LAST          : in  std_logic;
        WR_CHUNK_ID      : in  chunk_id_t;
        WR_TIMESTAMP     : in  timestamp_t;
        WR_SCORE         : in  std_logic_vector(31 downto 0);

        RD_VALID         : out std_logic;
        RD_READY         : in  std_logic;
        RD_DATA          : out raw_adc_batch_t;
        RD_LAST          : out std_logic;
        RD_CHUNK_ID      : out chunk_id_t;
        RD_TIMESTAMP     : out timestamp_t;
        RD_SCORE         : out std_logic_vector(31 downto 0)
    );
end entity EVENT_OUTPUT_FIFO;

architecture rtl of EVENT_OUTPUT_FIFO is
    constant EVENT_OUTPUT_WORD_WIDTH : integer :=
        RAW_ADC_BATCH_WIDTH + 1 + CHUNK_ID_WIDTH + TIMESTAMP_WIDTH + 32;
    constant DATA_LSB      : integer := 0;
    constant DATA_MSB      : integer := RAW_ADC_BATCH_WIDTH - 1;
    constant LAST_BIT      : integer := DATA_MSB + 1;
    constant CHUNK_ID_LSB  : integer := LAST_BIT + 1;
    constant CHUNK_ID_MSB  : integer := CHUNK_ID_LSB + CHUNK_ID_WIDTH - 1;
    constant TIMESTAMP_LSB : integer := CHUNK_ID_MSB + 1;
    constant TIMESTAMP_MSB : integer := TIMESTAMP_LSB + TIMESTAMP_WIDTH - 1;
    constant SCORE_LSB     : integer := TIMESTAMP_MSB + 1;
    constant SCORE_MSB     : integer := SCORE_LSB + 32 - 1;

    signal fifo_din   : std_logic_vector(EVENT_OUTPUT_WORD_WIDTH - 1 downto 0);
    signal fifo_dout  : std_logic_vector(EVENT_OUTPUT_WORD_WIDTH - 1 downto 0);
    signal fifo_full  : std_logic;
    signal fifo_empty : std_logic;
    signal fifo_wr_en : std_logic;
    signal fifo_rd_en : std_logic;

    signal rd_valid_r : std_logic := '0';
    signal rd_word_r  : std_logic_vector(EVENT_OUTPUT_WORD_WIDTH - 1 downto 0) := (others => '0');
begin
    fifo_din(DATA_MSB downto DATA_LSB) <= WR_DATA;
    fifo_din(LAST_BIT) <= WR_LAST;
    fifo_din(CHUNK_ID_MSB downto CHUNK_ID_LSB) <= std_logic_vector(WR_CHUNK_ID);
    fifo_din(TIMESTAMP_MSB downto TIMESTAMP_LSB) <= std_logic_vector(WR_TIMESTAMP);
    fifo_din(SCORE_MSB downto SCORE_LSB) <= WR_SCORE;

    fifo_wr_en <= WR_VALID and not fifo_full;
    fifo_rd_en <= not rd_valid_r and not fifo_empty;

    u_FIFO : xpm_fifo_sync
        generic map (
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "auto",
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => EVENT_OUTPUT_FIFO_DEPTH,
            FULL_RESET_VALUE    => 0,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => EVENT_OUTPUT_FIFO_DEPTH - 4,
            RD_DATA_COUNT_WIDTH => EVENT_OUTPUT_FIFO_ADDR_WIDTH + 1,
            READ_DATA_WIDTH     => EVENT_OUTPUT_WORD_WIDTH,
            READ_MODE           => "fwft",
            USE_ADV_FEATURES    => "0000",
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => EVENT_OUTPUT_WORD_WIDTH,
            WR_DATA_COUNT_WIDTH => EVENT_OUTPUT_FIFO_ADDR_WIDTH + 1
        )
        port map (
            sleep         => '0',
            rst           => RST,
            wr_clk        => CLK,
            wr_en         => fifo_wr_en,
            din           => fifo_din,
            full          => fifo_full,
            overflow      => open,
            wr_rst_busy   => open,
            rd_en         => fifo_rd_en,
            dout          => fifo_dout,
            empty         => fifo_empty,
            underflow     => open,
            rd_rst_busy   => open,
            prog_full     => open,
            prog_empty    => open,
            data_valid    => open,
            wr_data_count => open,
            rd_data_count => open,
            injectsbiterr => '0',
            injectdbiterr => '0',
            sbiterr       => open,
            dbiterr       => open
        );

    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                rd_valid_r <= '0';
                rd_word_r  <= (others => '0');
            else
                if rd_valid_r = '1' and RD_READY = '1' then
                    rd_valid_r <= '0';
                elsif rd_valid_r = '0' and fifo_empty = '0' then
                    rd_word_r  <= fifo_dout;
                    rd_valid_r <= '1';
                end if;
            end if;
        end if;
    end process;

    WR_READY     <= not fifo_full;
    RD_VALID     <= rd_valid_r;
    RD_DATA      <= rd_word_r(DATA_MSB downto DATA_LSB);
    RD_LAST      <= rd_word_r(LAST_BIT);
    RD_CHUNK_ID  <= unsigned(rd_word_r(CHUNK_ID_MSB downto CHUNK_ID_LSB));
    RD_TIMESTAMP <= unsigned(rd_word_r(TIMESTAMP_MSB downto TIMESTAMP_LSB));
    RD_SCORE     <= rd_word_r(SCORE_MSB downto SCORE_LSB);
end architecture rtl;
