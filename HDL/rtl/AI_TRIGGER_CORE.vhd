-- =============================================================================
-- AI_TRIGGER_CORE
-- Internal trigger core.  ADC ingest, chunking, waveform capture, and event
-- output are in CLK_ADC.  CNN inference is in CLK_CNN.
--
-- The DAQ-facing top owns any flat-bus adaptation.  This core intentionally
-- has no ADC source-clock input; upstream source-clock crossing is outside the
-- delivered trigger-system boundary.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_CORE is
    port (
        CLK_ADC        : in  std_logic;
        CLK_CNN        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;
        ADC_DATA4      : in  adc_data4_t;

        CNN_THRESH     : in  std_logic_vector(31 downto 0);

        CNN_TRIG       : out std_logic;
        CNN_OUT_DATA   : out std_logic_vector(31 downto 0);
        CNN_OUT_CHUNK_ID : out chunk_id_t;
        CNN_OUT_VALID  : out std_logic;

        EVENT_VALID    : out std_logic;
        EVENT_READY    : in  std_logic;
        EVENT_DATA     : out raw_adc_batch_t;
        EVENT_LAST     : out std_logic;
        EVENT_CHUNK_ID : out chunk_id_t;
        EVENT_TIMESTAMP : out timestamp_t;
        EVENT_SCORE    : out std_logic_vector(31 downto 0);
        DROPPED_TRIGGER_COUNT : out unsigned(31 downto 0);
        RING_MISS_COUNT       : out unsigned(31 downto 0);

        CHUNK_OVERFLOW : out std_logic
    );
end entity AI_TRIGGER_CORE;

architecture structural of AI_TRIGGER_CORE is

    signal lane_we    : std_logic_vector(N_LANES-1 downto 0);
    signal batch_data : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal dist_chunk_id : chunk_id_t;
    signal dist_timestamp : timestamp_t;
    signal lane_busy  : lane_busy_t;

    type score_arr_t is array (0 to N_LANES-1) of std_logic_vector(31 downto 0);
    signal lane_score : score_arr_t;
    signal lane_thresh : score_arr_t;
    signal lane_chunk_id : chunk_id_arr_t;
    signal lane_timestamp : timestamp_arr_t;
    signal lane_valid : std_logic_vector(N_LANES-1 downto 0);
    signal agg_score_data : std_logic_vector(31 downto 0) := (others => '0');
    signal agg_score_thresh : std_logic_vector(31 downto 0) := (others => '0');
    signal agg_score_chunk_id : chunk_id_t := (others => '0');
    signal agg_score_timestamp : timestamp_t := (others => '0');
    signal agg_score_valid : std_logic := '0';
    signal cnn_thresh_cnn : std_logic_vector(31 downto 0) := (others => '0');
    signal rst_adc : std_logic := '1';
    signal rst_cnn : std_logic := '1';

begin

    u_RST_ADC : entity work.RESET_SYNC
        port map (
            CLK       => CLK_ADC,
            RST_ASYNC => RST,
            RST_SYNC  => rst_adc
        );

    u_RST_CNN : entity work.RESET_SYNC
        port map (
            CLK       => CLK_CNN,
            RST_ASYNC => RST,
            RST_SYNC  => rst_cnn
        );

    u_CNN_THRESH_CDC : xpm_cdc_array_single
        generic map (
            DEST_SYNC_FF   => 2,
            INIT_SYNC_FF   => 0,
            SIM_ASSERT_CHK => 0,
            SRC_INPUT_REG  => 0,
            WIDTH          => 32
        )
        port map (
            src_clk  => CLK_ADC,
            src_in   => CNN_THRESH,
            dest_clk => CLK_CNN,
            dest_out => cnn_thresh_cnn
        );

    u_DIST : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC        => CLK_ADC,
            RST            => rst_adc,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => ADC_DATA4,
            LANE_BUSY      => lane_busy,
            LANE_WE        => lane_we,
            BATCH_DATA     => batch_data,
            CHUNK_ID       => dist_chunk_id,
            CHUNK_TIMESTAMP => dist_timestamp,
            CHUNK_OVERFLOW => CHUNK_OVERFLOW
        );

    gen_lanes : for i in 0 to N_LANES-1 generate
        u_LANE : entity work.CNN_CORE_LANE
            generic map (
                LANE_ID => i
            )
            port map (
                CLK_ADC    => CLK_ADC,
                CLK_CNN    => CLK_CNN,
                RST_ASYNC  => RST,
                RST_ADC    => rst_adc,
                RST_CNN    => rst_cnn,
                WR_EN      => lane_we(i),
                BATCH_DATA => batch_data,
                CHUNK_ID   => dist_chunk_id,
                CHUNK_TIMESTAMP => dist_timestamp,
                CNN_THRESH => cnn_thresh_cnn,
                CHUNK_BUSY => lane_busy(i),
                LANE_SCORE => lane_score(i),
                LANE_CHUNK_ID => lane_chunk_id(i),
                LANE_TIMESTAMP => lane_timestamp(i),
                LANE_THRESH => lane_thresh(i),
                LANE_VALID => lane_valid(i)
            );
    end generate;

    u_EVENT_PATH : entity work.EVENT_CAPTURE_PATH
        port map (
            CLK_ADC        => CLK_ADC,
            CLK_CNN        => CLK_CNN,
            RST_ADC        => rst_adc,
            RST_CNN        => rst_cnn,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => ADC_DATA4,
            SCORE_VALID    => agg_score_valid,
            SCORE_DATA     => agg_score_data,
            SCORE_CHUNK_ID => agg_score_chunk_id,
            SCORE_TIMESTAMP => agg_score_timestamp,
            CNN_THRESH     => agg_score_thresh,
            EVENT_VALID    => EVENT_VALID,
            EVENT_READY    => EVENT_READY,
            EVENT_DATA     => EVENT_DATA,
            EVENT_LAST     => EVENT_LAST,
            EVENT_CHUNK_ID => EVENT_CHUNK_ID,
            EVENT_TIMESTAMP => EVENT_TIMESTAMP,
            EVENT_SCORE    => EVENT_SCORE,
            DROPPED_TRIGGER_COUNT => DROPPED_TRIGGER_COUNT,
            RING_MISS_COUNT       => RING_MISS_COUNT
        );

    -- Result aggregation (CLK_CNN): registered comparator per lane, OR result.
    -- WRAPPER_TOP returns ap_fixed<22,11> byte-aligned into the low 22 bits of a
    -- 32-bit TDATA word: float_score = signed(score[21:0]) / 2048.
    process(CLK_CNN)
        variable any_trig  : std_logic;
        variable last_data : std_logic_vector(31 downto 0);
        variable last_chunk_id : chunk_id_t;
        variable last_timestamp : timestamp_t;
        variable last_valid: std_logic;
    begin
        if rising_edge(CLK_CNN) then
            if rst_cnn = '1' then
                CNN_TRIG <= '0';
                CNN_OUT_DATA <= (others => '0');
                CNN_OUT_CHUNK_ID <= (others => '0');
                CNN_OUT_VALID <= '0';
                agg_score_data <= (others => '0');
                agg_score_thresh <= (others => '0');
                agg_score_chunk_id <= (others => '0');
                agg_score_timestamp <= (others => '0');
                agg_score_valid <= '0';
            else
                any_trig   := '0';
                last_data  := (others => '0');
                agg_score_thresh <= (others => '0');
                last_chunk_id := (others => '0');
                last_timestamp := (others => '0');
                last_valid := '0';
                for i in 0 to N_LANES-1 loop
                    if lane_valid(i) = '1' then
                        last_data  := lane_score(i);
                        agg_score_thresh <= lane_thresh(i);
                        last_chunk_id := lane_chunk_id(i);
                        last_timestamp := lane_timestamp(i);
                        last_valid := '1';
                        if signed(lane_score(i)(21 downto 0)) >
                           signed(lane_thresh(i)(21 downto 0)) then
                            any_trig := '1';
                        end if;
                    end if;
                end loop;
                CNN_TRIG      <= any_trig;
                CNN_OUT_DATA  <= last_data;
                CNN_OUT_CHUNK_ID <= last_chunk_id;
                CNN_OUT_VALID <= last_valid;
                agg_score_data <= last_data;
                agg_score_chunk_id <= last_chunk_id;
                agg_score_timestamp <= last_timestamp;
                agg_score_valid <= last_valid;
            end if;
        end if;
    end process;

end architecture structural;
