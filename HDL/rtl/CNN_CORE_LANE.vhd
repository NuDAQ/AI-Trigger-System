-- =============================================================================
-- CNN_CORE_LANE
-- One parallel CNN inference lane.
--
-- Contains:
--   - 256 x 64-bit chunk buffer (register array, written from CLK_ADC)
--   - 4-phase CDC handshake (CLK_ADC <-> CLK_CNN)
--   - RST synchronizer (CLK_ADC -> CLK_CNN)
--   - CNN stream FSM (CLK_CNN): streams chunk to WRAPPER_TOP via ap_ctrl_hs + AXI-S
--   - WRAPPER_TOP instantiation (cnn_core inside)
--
-- CLK_ADC domain outputs:  CHUNK_BUSY
-- CLK_CNN domain outputs:  LANE_TRIG, LANE_SCORE, LANE_VALID
--
-- ap_ctrl_hs protocol (from HiLoGatedCNNTrigger notes):
--   - start must be held high until ready rises.
--   - input_valid + first data word must be asserted simultaneously with start.
--   - No bubbles in the input stream (input_valid stays high for all 256 words).
--
-- Buffer implementation note:
--   The chunk buffer is a plain register array (16384 FFs per lane).
--   For production, replace with a BRAM-based dual-clock buffer or use the
--   Xilinx 1024->64 async FIFO approach from CNN_FIFO_CONNECTOR.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity CNN_CORE_LANE is
    port (
        -- Clocks and reset (RST synchronous to CLK_ADC, active-high)
        CLK_ADC      : in  std_logic;
        CLK_CNN      : in  std_logic;
        RST          : in  std_logic;

        -- Write interface from ADC_CHUNK_DISTRIBUTOR (CLK_ADC domain)
        WR_EN        : in  std_logic;
        BATCH_ADDR   : in  std_logic_vector(3 downto 0);   -- 0-15
        BATCH_DATA   : in  std_logic_vector(N_BATCH_S*64-1 downto 0);  -- 1024-bit

        -- Status to distributor (CLK_ADC domain)
        CHUNK_BUSY   : out std_logic;   -- high while chunk not yet acknowledged by CNN

        -- Results (CLK_CNN domain)
        LANE_TRIG    : out std_logic;   -- 1-cycle pulse: score > CNN_THRESH (comparison in top)
        LANE_SCORE   : out std_logic_vector(15 downto 0);  -- ap_fixed<16,6> raw
        LANE_VALID   : out std_logic    -- 1-cycle pulse: new score latched
    );
end entity CNN_CORE_LANE;

architecture rtl of CNN_CORE_LANE is

    -- -------------------------------------------------------------------------
    -- WRAPPER_TOP component (Verilog, from cnn-core-wrapper dep)
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
    -- Chunk buffer: 256 x 64-bit
    -- Written from CLK_ADC (16 words per batch, 16 batches per chunk).
    -- Read from CLK_CNN (1 word per cycle, sequential).
    -- -------------------------------------------------------------------------
    type chunk_buf_t is array (0 to N_CHUNK_W-1) of std_logic_vector(63 downto 0);
    signal chunk_buf : chunk_buf_t := (others => (others => '0'));

    -- -------------------------------------------------------------------------
    -- CDC signals
    -- -------------------------------------------------------------------------
    -- CLK_ADC domain
    signal chunk_written_adc : std_logic := '0';
    signal chunk_ack_adc_ff  : std_logic_vector(1 downto 0) := (others => '0');

    -- CLK_CNN domain
    signal chunk_written_ff  : std_logic_vector(1 downto 0) := (others => '0');
    signal chunk_ack_cnn     : std_logic := '0';

    signal chunk_written_cnn : std_logic;
    signal chunk_ack_adc     : std_logic;

    -- -------------------------------------------------------------------------
    -- RST synchronizer (CLK_ADC -> CLK_CNN)
    -- Initialised to '1' so rst_n_cnn='0' from time 0 (before any CLK_CNN edge)
    -- -------------------------------------------------------------------------
    signal rst_cnn_ff : std_logic_vector(1 downto 0) := "11";
    signal rst_n_cnn  : std_logic;

    -- -------------------------------------------------------------------------
    -- CNN interface signals (CLK_CNN domain)
    -- -------------------------------------------------------------------------
    signal cnn_start     : std_logic := '0';
    signal cnn_done      : std_logic;
    signal cnn_idle      : std_logic;
    signal cnn_ready     : std_logic;
    signal cnn_in_data   : std_logic_vector(63 downto 0) := (others => '0');
    signal cnn_in_valid  : std_logic := '0';
    signal cnn_in_ready  : std_logic;
    signal cnn_out_data  : std_logic_vector(15 downto 0);
    signal cnn_out_valid : std_logic;

    -- -------------------------------------------------------------------------
    -- CNN stream FSM (CLK_CNN domain)
    -- -------------------------------------------------------------------------
    type cnn_fsm_t is (CC_IDLE, CC_STREAM, CC_WAIT_DONE, CC_ACK);
    signal cnn_state  : cnn_fsm_t := CC_IDLE;
    signal stream_cnt : integer range 0 to N_CHUNK_W-1 := 0;

    signal lane_score_r : std_logic_vector(15 downto 0) := (others => '0');
    signal lane_valid_r : std_logic := '0';

begin

    -- =========================================================================
    -- CLK_ADC DOMAIN
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- Chunk buffer write:  16 words per batch, parallel into buffer
    -- -------------------------------------------------------------------------
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            if WR_EN = '1' then
                for i in 0 to N_BATCH_S-1 loop
                    chunk_buf(to_integer(unsigned(BATCH_ADDR)) * N_BATCH_S + i)
                        <= BATCH_DATA((i+1)*64-1 downto i*64);
                end loop;
                -- Last batch of chunk: mark written
                if BATCH_ADDR = std_logic_vector(to_unsigned(N_BATCHES-1, 4)) then
                    chunk_written_adc <= '1';
                end if;
            end if;
            -- Clear when CNN domain acknowledges
            if chunk_ack_adc = '1' then
                chunk_written_adc <= '0';
            end if;
        end if;
    end process;

    -- 2-FF synchronizer: chunk_ack_cnn -> CLK_ADC
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            chunk_ack_adc_ff <= chunk_ack_adc_ff(0) & chunk_ack_cnn;
        end if;
    end process;
    chunk_ack_adc <= chunk_ack_adc_ff(1);

    CHUNK_BUSY <= chunk_written_adc;

    -- =========================================================================
    -- CLK_CNN DOMAIN
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- RST synchronizer
    -- -------------------------------------------------------------------------
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            rst_cnn_ff <= rst_cnn_ff(0) & RST;
        end if;
    end process;
    rst_n_cnn <= not rst_cnn_ff(1);

    -- -------------------------------------------------------------------------
    -- 2-FF synchronizer: chunk_written_adc -> CLK_CNN
    -- -------------------------------------------------------------------------
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            chunk_written_ff <= chunk_written_ff(0) & chunk_written_adc;
        end if;
    end process;
    chunk_written_cnn <= chunk_written_ff(1);

    -- -------------------------------------------------------------------------
    -- CNN stream FSM
    -- -------------------------------------------------------------------------
    process(CLK_CNN)
    begin
        if rising_edge(CLK_CNN) then
            if rst_n_cnn = '0' then
                cnn_state    <= CC_IDLE;
                cnn_start    <= '0';
                cnn_in_valid <= '0';
                cnn_in_data  <= (others => '0');
                stream_cnt   <= 0;
                chunk_ack_cnn <= '0';
                lane_valid_r  <= '0';
                lane_score_r  <= (others => '0');
            else
                lane_valid_r <= '0';  -- default: no pulse

                case cnn_state is

                    -- ---------------------------------------------------------
                    when CC_IDLE =>
                        chunk_ack_cnn <= '0';
                        if chunk_written_cnn = '1' then
                            -- Present word 0 and assert start simultaneously
                            cnn_in_data  <= chunk_buf(0);
                            cnn_in_valid <= '1';
                            cnn_start    <= '1';
                            stream_cnt   <= 0;
                            cnn_state    <= CC_STREAM;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_STREAM =>
                        -- Deassert start once ready rises (hold until then)
                        if cnn_ready = '1' then
                            cnn_start <= '0';
                        end if;

                        -- Advance stream on handshake
                        if cnn_in_ready = '1' then
                            if stream_cnt = N_CHUNK_W-1 then
                                -- Last word accepted
                                cnn_in_valid <= '0';
                                cnn_state    <= CC_WAIT_DONE;
                            else
                                stream_cnt  <= stream_cnt + 1;
                                -- Pre-fetch next word (async read from register array)
                                cnn_in_data <= chunk_buf(stream_cnt + 1);
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_WAIT_DONE =>
                        cnn_in_valid <= '0';
                        cnn_start    <= '0';
                        -- Latch score when output handshake occurs
                        if cnn_out_valid = '1' then
                            lane_score_r <= cnn_out_data;
                        end if;
                        -- Advance when ap_done fires
                        if cnn_done = '1' then
                            cnn_state <= CC_ACK;
                        end if;

                    -- ---------------------------------------------------------
                    when CC_ACK =>
                        lane_valid_r  <= '1';   -- one-cycle pulse
                        chunk_ack_cnn <= '1';   -- held high until ADC side clears written flag
                        cnn_state     <= CC_IDLE;

                end case;
            end if;
        end if;
    end process;

    LANE_SCORE <= lane_score_r;
    LANE_VALID <= lane_valid_r;
    -- LANE_TRIG comparison is done in AI_TRIGGER_TOP against CNN_THRESH
    LANE_TRIG  <= '0';  -- placeholder; top-level drives this from LANE_SCORE vs CNN_THRESH

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
            output_ready => '1'           -- always ready to receive score
        );

end architecture rtl;
