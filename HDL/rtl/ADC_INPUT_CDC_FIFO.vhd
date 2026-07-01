library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity ADC_INPUT_CDC_FIFO is
    port (
        WR_CLK         : in  std_logic;
        WR_RST         : in  std_logic;
        WR_VALID       : in  std_logic;
        WR_READY       : out std_logic;
        WR_DATA        : in  raw_adc_batch_t;

        RD_CLK         : in  std_logic;
        RD_RST         : in  std_logic;
        RD_VALID       : out std_logic;
        RD_READY       : in  std_logic;
        RD_DATA        : out raw_adc_batch_t;

        OVERFLOW_COUNT : out unsigned(31 downto 0)
    );
end entity ADC_INPUT_CDC_FIFO;

architecture rtl of ADC_INPUT_CDC_FIFO is
    signal fifo_full  : std_logic;
    signal fifo_empty : std_logic;
    signal fifo_dout  : raw_adc_batch_t;
    signal fifo_wr_en : std_logic;
    signal fifo_rd_en : std_logic;
    signal overflow_count_r : unsigned(31 downto 0) := (others => '0');
begin
    fifo_wr_en <= WR_VALID and not fifo_full;
    fifo_rd_en <= RD_READY and not fifo_empty;

    process(WR_CLK)
    begin
        if rising_edge(WR_CLK) then
            if WR_RST = '1' then
                overflow_count_r <= (others => '0');
            elsif WR_VALID = '1' and fifo_full = '1' then
                overflow_count_r <= overflow_count_r + 1;
            end if;
        end if;
    end process;

    u_FIFO : xpm_fifo_async
        generic map (
            CDC_SYNC_STAGES     => 2,
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "auto",
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => ADC_INPUT_FIFO_DEPTH,
            FULL_RESET_VALUE    => 0,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => ADC_INPUT_FIFO_DEPTH - 4,
            RD_DATA_COUNT_WIDTH => ADC_INPUT_FIFO_ADDR_WIDTH + 1,
            READ_DATA_WIDTH     => RAW_ADC_BATCH_WIDTH,
            READ_MODE           => "fwft",
            RELATED_CLOCKS      => 0,
            USE_ADV_FEATURES    => "0000",
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => RAW_ADC_BATCH_WIDTH,
            WR_DATA_COUNT_WIDTH => ADC_INPUT_FIFO_ADDR_WIDTH + 1
        )
        port map (
            sleep         => '0',
            rst           => WR_RST or RD_RST,
            wr_clk        => WR_CLK,
            wr_en         => fifo_wr_en,
            din           => WR_DATA,
            full          => fifo_full,
            overflow      => open,
            wr_rst_busy   => open,
            rd_clk        => RD_CLK,
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

    WR_READY       <= not fifo_full;
    RD_VALID       <= not fifo_empty;
    RD_DATA        <= fifo_dout;
    OVERFLOW_COUNT <= overflow_count_r;
end architecture rtl;
