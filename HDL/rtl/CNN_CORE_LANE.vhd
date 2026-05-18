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
--   After 16 writes the chunk is complete; chunk_done_adc is set.
--   The CNN FSM reads 128 x 128-bit entries using a 2:1 mux (word_sel) to
--   produce 256 x 64-bit AXI-S words for WRAPPER_TOP.
--
-- CHUNK_BUSY = fifo_full (CLK_ADC domain):
--   High while the FIFO holds an unread chunk (~640 ns at 200 MHz).
--   Falls low as soon as the CNN starts reading, long before inference ends.
--   This allows the ADC to write the next chunk while inference is still
--   running, which is required for 6-lane continuous 1 Gsps operation.
--
-- Control CDC (chunk_done / chunk_ack, 4-phase set/clear):
--   chunk_done_adc: set after 16th FIFO write, cleared by chunk_ack_adc sync.
--   chunk_done_cnn: 2-FF sync of chunk_done_adc; CNN FSM starts on rising edge.
--   chunk_ack_cnn:  set in CC_ACK (after inference done), cleared when
--                   chunk_done_cnn falls.
--   chunk_ack_adc:  2-FF sync of chunk_ack_cnn; clears chunk_done_adc.
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
            rst    : in  std_logic;
            wr_clk : in  std_logic;
            rd_clk : in  std_logic;
            din    : in  std_logic_vector(1023 downto 0);
            wr_en  : in  std_logic;
            rd_en  : in  std_logic;
            dout   : out std_logic_vector(127 downto 0);
            full   : out std_logic;
            empty  : out std_logic
        );
    end component;

    -- -------------------------------------------------------------------------
    -- CLK_ADC domain
    -- -------------------------------------------------------------------------
    signal wr_count       : integer range 0 to N_BATCHES-1 := 0;
    signal chunk_done_adc : std_logic := '0';
    signal fifo_full_s    : std_logic;

    -- 2-FF sync: chunk_ack_cnn -> CLK_ADC
    signal chunk_ack_adc_ff : std_logic_vector(1 downto 0) := (others => '0');
    signal chunk_ack_adc    : std_logic;

    -- -------------------------------------------------------------------------
    -- CLK_CNN domain
    -- -------------------------------------------------------------------------
    -- RST synchronizer (init '1' so rst_n_cnn = '0' before any CNN clock edge)
    signal rst_cnn_ff   : std_logic_vector(1 downto 0) := "11";
    signal rst_n_cnn    : std_logic;

    -- 2-FF sync: chunk_done_adc -> CLK_CNN
    signal chunk_done_ff  : std_logic_vector(1 downto 0) := (others => '0');
    signal chunk_done_cnn : std_logic;

    signal chunk_ack_cnn  : std_logic := '0';

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
    -- FIFO write + chunk_done_adc management
    -- -------------------------------------------------------------------------
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            if RST = '1' then
                wr_count       <= 0;
                chunk_done_adc <= '0';
            else
                -- Set chunk_done after 16th write; cleared by CNN ack sync
                if WR_EN = '1' then
                    if wr_count = N_BATCHES-1 then
                        wr_count       <= 0;
                        chunk_done_adc <= '1';
                    else
                        wr_count <= wr_count + 1;
                    end if;
                end if;
                if chunk_ack_adc = '1' then
                    chunk_done_adc <= '0';
                end if;
            end if;
        end if;
    end process;

    -- 2-FF sync: chunk_ack_cnn -> CLK_ADC
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            chunk_ack_adc_ff <= chunk_ack_adc_ff(0) & chunk_ack_cnn;
        end if;
    end process;
    chunk_ack_adc <= chunk_ack_adc_ff(1);

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

    -- 2-FF sync: chunk_done_adc -> CLK_CNN
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            chunk_done_ff <= chunk_done_ff(0) & chunk_done_adc;
        end if;
    end process;
    chunk_done_cnn <= chunk_done_ff(1);

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
                chunk_ack_cnn <= '0';
                lane_valid_r  <= '0';
                lane_score_r  <= (others => '0');
            else
                lane_valid_r <= '0';
                fifo_rd_en   <= '0';   -- default: don't pop

                case cnn_state is

                    -- ---------------------------------------------------------
                    when CC_IDLE =>
                        chunk_ack_cnn <= '0';
                        word_sel      <= '0';
                        stream_cnt    <= N_CHUNK_W;

                        if chunk_done_cnn = '1' and fifo_empty = '0' then
                            -- Assert start and first word simultaneously
                            cnn_start    <= '1';
                            cnn_in_valid <= '1';
                            -- FWFT: dout already holds first 128-bit entry
                            cnn_in_data  <= fifo_dout(63 downto 0);
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
                                -- Sent lower half; present upper half next cycle
                                word_sel     <= '1';
                                cnn_in_data  <= fifo_dout(127 downto 64);
                                -- Do NOT pop FIFO yet
                            else
                                -- Sent upper half; pop FIFO and prepare lower
                                -- half of the next entry (available next cycle
                                -- in FWFT mode after rd_en pulse)
                                word_sel     <= '0';
                                fifo_rd_en   <= '1';
                            end if;

                            if stream_cnt = 1 then
                                cnn_in_valid <= '0';
                                cnn_state    <= CC_WAIT_DONE;
                            end if;
                        end if;

                        -- Update cnn_in_data from newly popped FIFO entry
                        -- (takes effect one cycle after fifo_rd_en, FWFT)
                        if fifo_rd_en = '1' then
                            cnn_in_data <= fifo_dout(63 downto 0);
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
                        chunk_ack_cnn <= '1';
                        cnn_state     <= CC_IDLE;

                end case;
            end if;
        end if;
    end process;

    LANE_SCORE <= lane_score_r;
    LANE_VALID <= lane_valid_r;

    -- =========================================================================
    -- FIFO instantiation
    -- =========================================================================
    u_FIFO : fifo_async_1024_to_64
        port map (
            rst    => RST,
            wr_clk => CLK_ADC,
            rd_clk => CLK_CNN,
            din    => BATCH_DATA,
            wr_en  => WR_EN,
            rd_en  => fifo_rd_en,
            dout   => fifo_dout,
            full   => fifo_full_s,
            empty  => fifo_empty
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
