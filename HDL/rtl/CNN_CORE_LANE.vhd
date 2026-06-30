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
--   The CNN input stream may start after the first FIFO write of a chunk.
--   The remaining FIFO writes arrive faster than the 200 MHz stream consumes
--   them, so this hides the 256 ns ADC capture time.
--   The CNN input FSM reads 128 x 128-bit entries, where each entry contains
--   two timesteps x four 16-bit lanes for WRAPPER_TOP 4.x.
--
-- CHUNK_BUSY is asserted while this lane has a complete chunk that has not
-- yet been fully consumed by the CNN input stream.  It is cleared when the
-- 128-beat stream finishes, not when inference output is produced.
--
-- Control CDC:
--   The wide FIFO carries waveform batches across domains.  An XPM handshake
--   CDC primitive carries the matching chunk_id metadata.  The CNN side
--   acknowledges metadata only when the matching FIFO data is also available.
--
-- FIFO mode: First-Word-Fall-Through (FWFT).  dout is valid whenever not empty.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity CNN_CORE_LANE is
    generic (
        LANE_ID      : integer := 0;
        DEBUG_EVENTS : integer := 80
    );
    port (
        CLK_ADC      : in  std_logic;
        CLK_CNN      : in  std_logic;
        RST          : in  std_logic;   -- active-high, synchronous to CLK_ADC

        -- From ADC_CHUNK_DISTRIBUTOR (CLK_ADC domain)
        WR_EN        : in  std_logic;
        BATCH_DATA   : in  std_logic_vector(N_BATCH_S*64-1 downto 0);
        CHUNK_ID     : in  chunk_id_t;
        CHUNK_TIMESTAMP : in timestamp_t;

        -- To distributor (CLK_ADC domain) — lane cannot accept a full chunk
        CHUNK_BUSY   : out std_logic;

        -- Results (CLK_CNN domain)
        LANE_SCORE   : out std_logic_vector(31 downto 0);
        LANE_CHUNK_ID: out chunk_id_t;
        LANE_TIMESTAMP: out timestamp_t;
        LANE_VALID   : out std_logic
    );
end entity CNN_CORE_LANE;

architecture rtl of CNN_CORE_LANE is

    constant CHUNK_CNT_W : integer := 4;
    constant META_WIDTH : integer := CHUNK_ID_WIDTH + TIMESTAMP_WIDTH;
    subtype chunk_cnt_t is unsigned(CHUNK_CNT_W-1 downto 0);

    -- -------------------------------------------------------------------------
    -- WRAPPER_TOP (Verilog, from cnn-core-wrapper dependency)
    -- -------------------------------------------------------------------------
    component WRAPPER_TOP
        generic (
            INPUT_WIDTH   : integer := 128;
            OUTPUT_WIDTH  : integer := 32;
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
            input_data   : in  std_logic_vector(127 downto 0);
            input_valid  : in  std_logic;
            input_ready  : out std_logic;
            output_data  : out std_logic_vector(31 downto 0);
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
    signal chunk_busy_adc  : std_logic := '0';
    signal fifo_full_s    : std_logic;
    type chunk_id_mem_t is array (0 to 2**CHUNK_CNT_W - 1) of chunk_id_t;

    signal chunk_id_src_send    : std_logic := '0';
    signal chunk_id_src_rcv     : std_logic;
    signal chunk_id_src_pending : std_logic := '0';
    signal chunk_id_src_data    : std_logic_vector(META_WIDTH-1 downto 0) := (others => '0');

    -- 2-FF sync: stream_done_toggle_cnn -> CLK_ADC
    signal stream_done_adc_ff : std_logic_vector(1 downto 0) := (others => '0');
    signal stream_done_seen_adc : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- CLK_CNN domain
    -- -------------------------------------------------------------------------
    -- RST synchronizer (init '1' so rst_n_cnn = '0' before any CNN clock edge)
    signal rst_cnn_ff   : std_logic_vector(1 downto 0) := "11";
    signal rst_n_cnn    : std_logic;

    signal started_count_cnn : chunk_cnt_t := (others => '0');
    signal stream_done_toggle_cnn : std_logic := '0';

    signal chunk_id_dest_req  : std_logic;
    signal chunk_id_dest_ack  : std_logic := '0';
    signal chunk_id_dest_data : std_logic_vector(META_WIDTH-1 downto 0);
    signal chunk_id_meta_valid : std_logic := '0';
    signal chunk_id_meta_data  : chunk_id_t := (others => '0');
    signal timestamp_meta_data : timestamp_t := (others => '0');
    signal chunk_id_dest_seen  : std_logic := '0';

    -- synthesis translate_off
    signal dbg_adc_events : integer := 0;
    signal dbg_cnn_events : integer := 0;
    -- synthesis translate_on

    -- FIFO read side
    signal fifo_dout  : std_logic_vector(127 downto 0);
    signal fifo_empty : std_logic;
    signal fifo_rd_en : std_logic := '0';

    -- CNN interface
    signal cnn_start     : std_logic := '0';
    signal cnn_done      : std_logic;
    signal cnn_idle      : std_logic;
    signal cnn_ready     : std_logic;
    signal cnn_in_data   : std_logic_vector(127 downto 0);
    signal cnn_in_valid  : std_logic := '0';
    signal cnn_in_ready  : std_logic;
    signal cnn_out_data  : std_logic_vector(31 downto 0);
    signal cnn_out_valid : std_logic;

    -- Stream FSM.  Output capture is intentionally independent: LANE_BUSY is
    -- released when the 128-beat AXIS input transaction has been accepted, not
    -- when the later CNN output arrives.  The HLS dataflow core behaves like a
    -- continuously-started pipeline, so adjacent accepted chunks are streamed
    -- back-to-back instead of waiting for done/idle.
    type cnn_fsm_t is (CC_IDLE, CC_STREAM);
    signal cnn_state  : cnn_fsm_t := CC_IDLE;
    signal stream_cnt : integer range 0 to N_CHUNK_BEATS_CNN := 0;

    signal lane_score_r : std_logic_vector(31 downto 0) := (others => '0');
    signal lane_chunk_id_r : chunk_id_t := (others => '0');
    signal lane_timestamp_r : timestamp_t := (others => '0');
    signal lane_valid_r : std_logic := '0';
    signal score_id_mem : chunk_id_mem_t := (others => (others => '0'));
    type timestamp_mem_t is array (0 to 2**CHUNK_CNT_W - 1) of timestamp_t;
    signal score_timestamp_mem : timestamp_mem_t := (others => (others => '0'));
    signal score_id_wr_idx : integer range 0 to 2**CHUNK_CNT_W - 1 := 0;
    signal score_id_rd_idx : integer range 0 to 2**CHUNK_CNT_W - 1 := 0;

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of stream_done_adc_ff : signal is "TRUE";
    attribute ASYNC_REG of rst_cnn_ff : signal is "TRUE";

begin

    cnn_in_data <= fifo_dout;

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
                chunk_busy_adc  <= '0';
                stream_done_seen_adc <= '0';
                chunk_id_src_send <= '0';
                chunk_id_src_pending <= '0';
                chunk_id_src_data <= (others => '0');
            else
                if chunk_id_src_rcv = '1' then
                    chunk_id_src_send <= '0';
                    chunk_id_src_pending <= '0';
                else
                    chunk_id_src_send <= chunk_id_src_pending;
                end if;

                if stream_done_adc_ff(1) /= stream_done_seen_adc then
                    stream_done_seen_adc <= stream_done_adc_ff(1);
                    chunk_busy_adc <= '0';
                    -- synthesis translate_off
                    if dbg_adc_events < DEBUG_EVENTS then
                        report "LANE" & integer'image(LANE_ID) &
                               " ADC busy_clear stream_done_seen=" &
                               std_logic'image(stream_done_adc_ff(1)) &
                               " wr_count=" & integer'image(wr_count);
                        dbg_adc_events <= dbg_adc_events + 1;
                    end if;
                    -- synthesis translate_on
                end if;

                if WR_EN = '1' then
                    if wr_count = 0 then
                        chunk_id_src_send <= '1';
                        chunk_id_src_data <= std_logic_vector(CHUNK_TIMESTAMP) &
                                             std_logic_vector(CHUNK_ID);
                        chunk_id_src_pending <= '1';
                        chunk_count_adc <= chunk_count_adc + 1;
                        chunk_busy_adc  <= '1';
                        -- synthesis translate_off
                        if dbg_adc_events < DEBUG_EVENTS then
                            report "LANE" & integer'image(LANE_ID) &
                                   " ADC chunk_accept count=" &
                                   integer'image(to_integer(chunk_count_adc + 1)) &
                                   " fifo_full=" & std_logic'image(fifo_full_s);
                            dbg_adc_events <= dbg_adc_events + 1;
                        end if;
                        -- synthesis translate_on
                    end if;

                    if wr_count = N_BATCHES-1 then
                        wr_count <= 0;
                    else
                        wr_count <= wr_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            stream_done_adc_ff <= stream_done_adc_ff(0) & stream_done_toggle_cnn;
        end if;
    end process;

    CHUNK_BUSY <= chunk_busy_adc or fifo_full_s or chunk_id_src_pending;

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
                fifo_rd_en   <= '0';
                stream_cnt   <= 0;
                started_count_cnn <= (others => '0');
                stream_done_toggle_cnn <= '0';
                lane_valid_r <= '0';
                lane_score_r <= (others => '0');
                lane_chunk_id_r <= (others => '0');
                lane_timestamp_r <= (others => '0');
                score_id_wr_idx <= 0;
                score_id_rd_idx <= 0;
                chunk_id_dest_ack <= '0';
                chunk_id_meta_valid <= '0';
                chunk_id_meta_data <= (others => '0');
                timestamp_meta_data <= (others => '0');
                chunk_id_dest_seen <= '0';
            else
                lane_valid_r <= '0';
                fifo_rd_en   <= '0';   -- default: don't pop
                chunk_id_dest_ack <= '0';
                if chunk_id_dest_req = '0' then
                    chunk_id_dest_seen <= '0';
                elsif chunk_id_dest_seen = '0' and chunk_id_meta_valid = '0' then
                    chunk_id_meta_data <= unsigned(chunk_id_dest_data(CHUNK_ID_WIDTH - 1 downto 0));
                    timestamp_meta_data <= unsigned(chunk_id_dest_data(META_WIDTH - 1 downto CHUNK_ID_WIDTH));
                    chunk_id_meta_valid <= '1';
                    chunk_id_dest_seen <= '1';
                end if;
                if cnn_out_valid = '1' then
                    lane_score_r <= cnn_out_data;
                    lane_chunk_id_r <= score_id_mem(score_id_rd_idx);
                    lane_timestamp_r <= score_timestamp_mem(score_id_rd_idx);
                    lane_valid_r <= '1';
                    if score_id_rd_idx = 2**CHUNK_CNT_W - 1 then
                        score_id_rd_idx <= 0;
                    else
                        score_id_rd_idx <= score_id_rd_idx + 1;
                    end if;
                    -- synthesis translate_off
                    if dbg_cnn_events < DEBUG_EVENTS then
                        report "LANE" & integer'image(LANE_ID) &
                               " CNN output_valid score_raw=" &
                               integer'image(to_integer(signed(cnn_out_data(21 downto 0)))) &
                               " started=" &
                               integer'image(to_integer(started_count_cnn));
                        dbg_cnn_events <= dbg_cnn_events + 1;
                    end if;
                    -- synthesis translate_on
                end if;

                case cnn_state is

                    -- ---------------------------------------------------------
                    when CC_IDLE =>
                        cnn_start    <= '0';
                        cnn_in_valid <= '0';
                        stream_cnt    <= N_CHUNK_BEATS_CNN;

                        if chunk_id_meta_valid = '1' and fifo_empty = '0' then
                            -- Assert start and first word simultaneously.
                            -- Keep start asserted through the input stream; the
                            -- wrapper/HLS TB treats ap_start as a continuous
                            -- enable and ap_done is only an output completion.
                            cnn_start    <= '1';
                            cnn_in_valid <= '1';
                            chunk_id_meta_valid <= '0';
                            score_id_mem(score_id_wr_idx) <= chunk_id_meta_data;
                            score_timestamp_mem(score_id_wr_idx) <= timestamp_meta_data;
                            if score_id_wr_idx = 2**CHUNK_CNT_W - 1 then
                                score_id_wr_idx <= 0;
                            else
                                score_id_wr_idx <= score_id_wr_idx + 1;
                            end if;
                            started_count_cnn <= started_count_cnn + 1;
                            cnn_state    <= CC_STREAM;
                            -- synthesis translate_off
                            if dbg_cnn_events < DEBUG_EVENTS then
                                report "LANE" & integer'image(LANE_ID) &
                                       " started_next=" &
                                       integer'image(to_integer(started_count_cnn + 1)) &
                                       " fifo_empty=" & std_logic'image(fifo_empty) &
                                       " ready=" & std_logic'image(cnn_ready) &
                                       " idle=" & std_logic'image(cnn_idle);
                                dbg_cnn_events <= dbg_cnn_events + 1;
                            end if;
                            -- synthesis translate_on
                        end if;

                    -- ---------------------------------------------------------
                    when CC_STREAM =>
                        -- Keep ap_start high while actively feeding the HLS
                        -- dataflow pipeline.  Do not wait for ap_done, and do
                        -- not use ap_ready as the stream-completion condition.
                        cnn_start <= '1';

                        if cnn_in_ready = '1' then
                            stream_cnt <= stream_cnt - 1;
                            fifo_rd_en <= '1';

                            if stream_cnt = 1 then
                                stream_done_toggle_cnn <= not stream_done_toggle_cnn;

                                if chunk_id_meta_valid = '1' and fifo_empty = '0' then
                                    cnn_start    <= '1';
                                    cnn_in_valid <= '1';
                                    stream_cnt   <= N_CHUNK_BEATS_CNN;
                                    chunk_id_meta_valid <= '0';
                                    score_id_mem(score_id_wr_idx) <= chunk_id_meta_data;
                                    score_timestamp_mem(score_id_wr_idx) <= timestamp_meta_data;
                                    if score_id_wr_idx = 2**CHUNK_CNT_W - 1 then
                                        score_id_wr_idx <= 0;
                                    else
                                        score_id_wr_idx <= score_id_wr_idx + 1;
                                    end if;
                                    started_count_cnn <= started_count_cnn + 1;
                                    cnn_state    <= CC_STREAM;
                                    -- synthesis translate_off
                                    if dbg_cnn_events < DEBUG_EVENTS then
                                        report "LANE" & integer'image(LANE_ID) &
                                               " started_next=" &
                                               integer'image(to_integer(started_count_cnn + 1)) &
                                               " fifo_empty=" & std_logic'image(fifo_empty) &
                                               " ready=" & std_logic'image(cnn_ready) &
                                               " idle=" & std_logic'image(cnn_idle);
                                        dbg_cnn_events <= dbg_cnn_events + 1;
                                    end if;
                                    -- synthesis translate_on
                                else
                                    cnn_start    <= '0';
                                    cnn_in_valid <= '0';
                                    cnn_state    <= CC_IDLE;
                                    -- synthesis translate_off
                                    if dbg_cnn_events < DEBUG_EVENTS then
                                        report "LANE" & integer'image(LANE_ID) &
                                               " started=" &
                                               integer'image(to_integer(started_count_cnn)) &
                                               " fifo_empty=" & std_logic'image(fifo_empty) &
                                               " ready=" & std_logic'image(cnn_ready);
                                        dbg_cnn_events <= dbg_cnn_events + 1;
                                    end if;
                                    -- synthesis translate_on
                                end if;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    LANE_SCORE <= lane_score_r;
    LANE_CHUNK_ID <= lane_chunk_id_r;
    LANE_TIMESTAMP <= lane_timestamp_r;
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

    u_CHUNK_ID_CDC : xpm_cdc_handshake
        generic map (
            DEST_EXT_HSK   => 0,
            DEST_SYNC_FF   => 2,
            INIT_SYNC_FF   => 0,
            SIM_ASSERT_CHK => 0,
            SRC_SYNC_FF    => 2,
            WIDTH          => META_WIDTH
        )
        port map (
            src_clk   => CLK_ADC,
            src_in    => chunk_id_src_data,
            src_send  => chunk_id_src_send,
            src_rcv   => chunk_id_src_rcv,
            dest_clk  => CLK_CNN,
            dest_out  => chunk_id_dest_data,
            dest_req  => chunk_id_dest_req,
            dest_ack  => chunk_id_dest_ack
        );

    -- =========================================================================
    -- WRAPPER_TOP instantiation
    -- =========================================================================
    u_WRAPPER : WRAPPER_TOP
        generic map (
            INPUT_WIDTH   => 128,
            OUTPUT_WIDTH  => 32,
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
