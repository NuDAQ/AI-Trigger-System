-- =============================================================================
-- CNN_CORE_LANE
-- One parallel CNN inference lane.
--
-- Buffer architecture (replaces register array from v1):
--   fifo_async_1024_to_64 — same Xilinx IP used in the original
--   CNN_FIFO_CONNECTOR.  Write port: 1024-bit x 16 deep (CLK_ADC).
--   Read port: 128-bit x 128 deep (CLK_CNN).  The FIFO is the CDC mechanism.
--
--   One 1024-bit FIFO write per ADC batch (16 timesteps x 4 ch x 16-bit).
--   After 16 writes the completed-chunk counter is incremented.
--   The CNN FSM reads 128 x 128-bit entries using a 2:1 mux (word_sel) to
--   produce 256 x 64-bit AXI-S words for WRAPPER_TOP.
--
-- CHUNK_BUSY = fifo_full (CLK_ADC domain):
--   High while the FIFO holds an unread chunk (~640 ns at 200 MHz).
--   Falls low as soon as the CNN starts reading, long before inference ends.
--   This allows the ADC to write the next chunk while inference is still
--   running, which is required for 6-lane continuous 1 Gsps operation.
--
-- Control CDC:
--   The FIFO carries data across domains.  A Gray-coded completion counter
--   carries the number of fully written chunks.  The CNN side keeps its own
--   started counter and launches whenever completed_count > started_count.
--   This allows the FIFO to hold more than one completed chunk; a single
--   chunk_done bit would lose completions while a previous chunk is running.
--
-- FIFO mode: First-Word-Fall-Through (FWFT).  dout is valid whenever not empty.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity CNN_CORE_LANE is
    port (
        CLK_ADC      : in  std_logic;
        CLK_CNN      : in  std_logic;
        RST          : in  std_logic;   -- active-high, synchronous to CLK_ADC

        -- From ADC_CHUNK_DISTRIBUTOR (CLK_ADC domain)
        WR_EN        : in  std_logic;
        BATCH_DATA   : in  std_logic_vector(N_BATCH_S*64-1 downto 0);

        -- To distributor (CLK_ADC domain) — FIFO write-side full
        CHUNK_BUSY   : out std_logic;

        -- Results (CLK_CNN domain)
        LANE_SCORE   : out std_logic_vector(15 downto 0);
        LANE_VALID   : out std_logic
    );
end entity CNN_CORE_LANE;

architecture rtl of CNN_CORE_LANE is

    constant CHUNK_CNT_W : integer := 4;
    subtype chunk_cnt_t is unsigned(CHUNK_CNT_W-1 downto 0);

    function bin_to_gray(b : chunk_cnt_t) return std_logic_vector is
        variable g : chunk_cnt_t;
        variable shifted : chunk_cnt_t;
    begin
        shifted := (others => '0');
        shifted(CHUNK_CNT_W-2 downto 0) := b(CHUNK_CNT_W-1 downto 1);
        g := b xor shifted;
        return std_logic_vector(g);
    end function;

    function gray_to_bin(g : std_logic_vector(CHUNK_CNT_W-1 downto 0)) return chunk_cnt_t is
        variable b : chunk_cnt_t;
    begin
        b(CHUNK_CNT_W-1) := g(CHUNK_CNT_W-1);
        for i in CHUNK_CNT_W-2 downto 0 loop
            b(i) := b(i+1) xor g(i);
        end loop;
        return b;
    end function;

    -- -------------------------------------------------------------------------
    -- WRAPPER_TOP (Verilog, from cnn-core-wrapper dependency)
    -- -------------------------------------------------------------------------
    component WRAPPER_TOP
        generic (
            INPUT_WIDTH   : integer := 64;
            OUTPUT_WIDTH  : integer := 16;
            NUM_TIMESTEPS : integer := 256;
            NUM_CHANNELS  : integer := 4
        );
        port (
            clk          : in  std_logic;
            rst_n        : in  std_logic;
            start        : in  std_logic;
            done         : out std_logic;
            idle         : out std_logic;
            ready        : out std_logic;
            input_data   : in  std_logic_vector(63 downto 0);
            input_valid  : in  std_logic;
            input_ready  : out std_logic;
            output_data  : out std_logic_vector(15 downto 0);
            output_valid : out std_logic;
            output_ready : in  std_logic
        );
    end component;

    -- -------------------------------------------------------------------------
    -- Async FIFO: 1024-bit write (CLK_ADC) / 128-bit read (CLK_CNN)
    -- Depth: 16 write entries = 128 read entries.
    -- FWFT mode: dout valid when not empty, rd_en pops current entry.
    -- Must be generated as Xilinx FIFO Generator IP with these settings:
    --   Write Width = 1024, Write Depth = 16
    --   Read  Width = 128,  (asymmetric, auto-calculated depth = 128)
    --   Independent Clocks, First Word Fall Through
    -- -------------------------------------------------------------------------
    component fifo_async_1024_to_64
        port (
            rst         : in  std_logic;
            wr_clk      : in  std_logic;
            rd_clk      : in  std_logic;
            din         : in  std_logic_vector(1023 downto 0);
            wr_en       : in  std_logic;
            rd_en       : in  std_logic;
            dout        : out std_logic_vector(127 downto 0);
            full        : out std_logic;
            empty       : out std_logic;
            wr_rst_busy : out std_logic;   -- high while write port is in reset
            rd_rst_busy : out std_logic    -- high while read port is in reset
        );
    end component;

    -- -------------------------------------------------------------------------
    -- CLK_ADC domain
    -- -------------------------------------------------------------------------
    signal wr_count       : integer range 0 to N_BATCHES-1 := 0;
    signal chunk_count_adc : chunk_cnt_t := (others => '0');
    signal chunk_gray_adc  : std_logic_vector(CHUNK_CNT_W-1 downto 0) := (others => '0');
    signal fifo_full_s    : std_logic;

    -- -------------------------------------------------------------------------
    -- CLK_CNN domain
    -- -------------------------------------------------------------------------
    -- RST synchronizer (init '1' so rst_n_cnn = '0' before any CNN clock edge)
    signal rst_cnn_ff   : std_logic_vector(1 downto 0) := "11";
    signal rst_n_cnn    : std_logic;

    -- 2-FF sync: chunk_gray_adc -> CLK_CNN
    signal chunk_gray_ff  : std_logic_vector(CHUNK_CNT_W*2-1 downto 0) := (others => '0');
    signal chunk_count_cnn : chunk_cnt_t := (others => '0');
    signal started_count_cnn : chunk_cnt_t := (others => '0');
    signal pending_count_cnn : chunk_cnt_t;

    -- FIFO read side
    signal fifo_dout  : std_logic_vector(127 downto 0);
    signal fifo_empty : std_logic;
    signal fifo_rd_en : std_logic := '0';

    -- CNN interface
    signal cnn_start     : std_logic := '0';
    signal cnn_done      : std_logic;
    signal cnn_idle      : std_logic;
    signal cnn_ready     : std_logic;
    signal cnn_in_data   : std_logic_vector(63 downto 0) := (others => '0');
    signal cnn_in_valid  : std_logic := '0';
    signal cnn_in_ready  : std_logic;
    signal cnn_out_data  : std_logic_vector(15 downto 0);
    signal cnn_out_valid : std_logic;

    -- Stream FSM
    type cnn_fsm_t is (CC_IDLE, CC_STREAM, CC_WAIT_DONE, CC_ACK);
    signal cnn_state  : cnn_fsm_t := CC_IDLE;
    signal stream_cnt : integer range 0 to N_CHUNK_W := 0;
    signal word_sel   : std_logic := '0';

    signal lane_score_r : std_logic_vector(15 downto 0) := (others => '0');
    signal lane_valid_r : std_logic := '0';

begin

    -- =========================================================================
    -- CLK_ADC DOMAIN
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- FIFO write + completed-chunk counter
    -- -------------------------------------------------------------------------
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            if RST = '1' then
                wr_count       <= 0;
                chunk_count_adc <= (others => '0');
                chunk_gray_adc  <= (others => '0');
            else
                if WR_EN = '1' then
                    if wr_count = N_BATCHES-1 then
                        wr_count        <= 0;
                        chunk_count_adc <= chunk_count_adc + 1;
                        chunk_gray_adc  <= bin_to_gray(chunk_count_adc + 1);
                    else
                        wr_count <= wr_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- CHUNK_BUSY = FIFO full (write side).
    -- Falls low as soon as the CNN reads the first entry, allowing the next
    -- chunk to be written while inference is still in progress.
    CHUNK_BUSY <= fifo_full_s;

    -- =========================================================================
    -- CLK_CNN DOMAIN
    -- =========================================================================

    -- RST synchronizer
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            rst_cnn_ff <= rst_cnn_ff(0) & RST;
        end if;
    end process;
    rst_n_cnn <= not rst_cnn_ff(1);

    -- 2-FF sync: completed-chunk Gray counter -> CLK_CNN
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            chunk_gray_ff(CHUNK_CNT_W-1 downto 0) <= chunk_gray_adc;
            chunk_gray_ff(CHUNK_CNT_W*2-1 downto CHUNK_CNT_W) <=
                chunk_gray_ff(CHUNK_CNT_W-1 downto 0);
        end if;
    end process;
    chunk_count_cnn <= gray_to_bin(chunk_gray_ff(CHUNK_CNT_W*2-1 downto CHUNK_CNT_W));
    pending_count_cnn <= chunk_count_cnn - started_count_cnn;

    -- -------------------------------------------------------------------------
    -- CNN stream FSM + FIFO read logic (mirrors original CNN_FIFO_CONNECTOR)
    -- -------------------------------------------------------------------------
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            if rst_n_cnn = '0' then
                cnn_state    <= CC_IDLE;
                cnn_start    <= '0';
                cnn_in_valid <= '0';
                cnn_in_data  <= (others => '0');
                fifo_rd_en   <= '0';
                word_sel     <= '0';
                stream_cnt   <= 0;
                started_count_cnn <= (others => '0');
                lane_valid_r  <= '0';
                lane_score_r  <= (others => '0');
            else
                lane_valid_r <= '0';
                fifo_rd_en   <= '0';   -- default: don't pop

                case cnn_state is

                    -- ---------------------------------------------------------
                    when CC_IDLE =>
                        word_sel      <= '0';
                        stream_cnt    <= N_CHUNK_W;

                        if pending_count_cnn /= 0 and fifo_empty = '0' then
                            -- Assert start and first word simultaneously
                            cnn_start    <= '1';
                            cnn_in_valid <= '1';
                            -- FWFT: dout already holds first 128-bit entry
                            cnn_in_data  <= fifo_dout(63 downto 0);
                            started_count_cnn <= started_count_cnn + 1;
                            cnn_state    <= CC_STREAM;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_STREAM =>
                        -- Deassert start when WRAPPER_TOP signals ready
                        if cnn_ready = '1' then
                            cnn_start <= '0';
                        end if;

                        if cnn_in_ready = '1' then
                            stream_cnt <= stream_cnt - 1;

                            if word_sel = '0' then
                                -- CNN just consumed the LOWER half of entry N.
                                -- Pre-load the UPPER half of entry N (dout unchanged).
                                -- Assert rd_en now: entry N+1 will appear at dout
                                -- exactly one cycle later (FWFT latency = 1).
                                cnn_in_data <= fifo_dout(127 downto 64);
                                fifo_rd_en  <= '1';
                                word_sel    <= '1';
                            else
                                -- CNN just consumed the UPPER half of entry N.
                                -- rd_en was asserted last cycle; dout now holds
                                -- entry N+1. Pre-load its LOWER half.
                                cnn_in_data <= fifo_dout(63 downto 0);
                                word_sel    <= '0';
                                -- fifo_rd_en stays '0' (default)
                            end if;

                            if stream_cnt = 1 then
                                cnn_in_valid <= '0';
                                cnn_state    <= CC_WAIT_DONE;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_WAIT_DONE =>
                        cnn_in_valid <= '0';
                        cnn_start    <= '0';
                        if cnn_out_valid = '1' then
                            lane_score_r <= cnn_out_data;
                        end if;
                        if cnn_done = '1' then
                            cnn_state <= CC_ACK;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_ACK =>
                        lane_valid_r  <= '1';
                        cnn_state     <= CC_IDLE;

                end case;
            end if;
        end if;
    end process;

    LANE_SCORE <= lane_score_r;
    LANE_VALID <= lane_valid_r;

    -- =========================================================================
    -- FIFO instantiation
    -- IP settings (Xilinx FIFO Generator 13.2):
    --   Basic       : Independent Clocks Block RAM, Sync Stages = 2
    --   Native Ports: First Word Fall Through, Asymmetric Port Width
    --                 Write Width = 1024, Write Depth = 32  (actual ~31)
    --                 Read  Width = 128,  Read  Depth = 128 (auto)
    --                 Output Registers = off (FWFT uses embedded BRAM reg)
    --   Status Flags: all off
    --   Data Counts : all off
    -- =========================================================================
    u_FIFO : fifo_async_1024_to_64
        port map (
            rst         => RST,
            wr_clk      => CLK_ADC,
            rd_clk      => CLK_CNN,
            din         => BATCH_DATA,
            wr_en       => WR_EN,
            rd_en       => fifo_rd_en,
            dout        => fifo_dout,
            full        => fifo_full_s,
            empty       => fifo_empty,
            wr_rst_busy => open,
            rd_rst_busy => open
        );

    -- =========================================================================
    -- WRAPPER_TOP instantiation
    -- =========================================================================
    u_WRAPPER : WRAPPER_TOP
        generic map (
            INPUT_WIDTH   => 64,
            OUTPUT_WIDTH  => 16,
            NUM_TIMESTEPS => 256,
            NUM_CHANNELS  => 4
        )
        port map (
            clk          => CLK_CNN,
            rst_n        => rst_n_cnn,
            start        => cnn_start,
            done         => cnn_done,
            idle         => cnn_idle,
            ready        => cnn_ready,
            input_data   => cnn_in_data,
            input_valid  => cnn_in_valid,
            input_ready  => cnn_in_ready,
            output_data  => cnn_out_data,
            output_valid => cnn_out_valid,
            output_ready => '1'
        );

end architecture rtl;
