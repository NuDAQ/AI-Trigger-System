-- =============================================================================
-- AI_TRIGGER_CORE
-- Shared runtime-selectable trigger core.  The waveform ring and all mode
-- control live in CLK_ADC.  Five CNN lanes are shared by continuous AI and
-- Hi-Lo-gated AI work; no trigger mode duplicates a CNN or waveform store.
-- CNN scores and thresholds use the wrapper's signed ap_fixed<22,11> payload
-- in bits 21 downto 0; CNN_RESULT_ARBITER performs the comparison.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_CORE is
    port (
        CLK_ADC        : in  std_logic;
        CLK_CNN        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;
        ADC_DATA4      : in  adc_data4_t;

        TRIGGER_MODE   : in  std_logic_vector(3 downto 0);
        FORCE_TRIGGER  : in  std_logic;
        CNN_THRESH     : in  std_logic_vector(31 downto 0);
        HL_THRESH      : in  std_logic_vector(11 downto 0);
        HILO_WINDOW    : in  std_logic_vector(4 downto 0);
        COINC_WINDOW   : in  std_logic_vector(5 downto 0);
        BIN_THR        : in  std_logic_vector(3 downto 0);

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
        EVENT_TRIGGER_OFFSET : out beat_offset_t;
        EVENT_SCORE    : out std_logic_vector(31 downto 0);

        ACTIVE_TRIGGER_MODE  : out std_logic_vector(3 downto 0);
        MODE_SWITCH_PENDING  : out std_logic;
        INVALID_TRIGGER_MODE : out std_logic;
        HILO_BLANKING        : out std_logic;
        HILO_CONFIG_ERROR    : out std_logic;
        EVENT_LOSS           : out std_logic;
        DROPPED_TRIGGER_COUNT : out unsigned(31 downto 0);
        RING_MISS_COUNT       : out unsigned(31 downto 0);
        CHUNK_OVERFLOW        : out std_logic
    );
end entity AI_TRIGGER_CORE;

architecture structural of AI_TRIGGER_CORE is
    signal rst_adc : std_logic := '1';
    signal rst_cnn : std_logic := '1';

    signal live_ai_enable : std_logic;
    signal live_lane_we : std_logic_vector(N_LANES - 1 downto 0);
    signal live_batch_data : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal live_chunk_id : chunk_id_t;
    signal live_timestamp : timestamp_t;
    signal chunk_overflow_i : std_logic;

    signal gated_lane_we : std_logic_vector(N_LANES - 1 downto 0);
    signal gated_batch_data : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal gated_start_chunk : chunk_id_t;
    signal gated_start_offset : beat_offset_t;
    signal gated_timestamp : timestamp_t;
    signal gated_trigger_offset : beat_offset_t;
    signal gated_thresh : std_logic_vector(31 downto 0);

    signal lane_we : std_logic_vector(N_LANES - 1 downto 0);
    signal lane_batch_data : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal lane_start_chunk : chunk_id_t;
    signal lane_start_offset_common : beat_offset_t;
    signal lane_timestamp_common : timestamp_t;
    signal lane_trigger_offset_common : beat_offset_t;
    signal lane_thresh_common : std_logic_vector(31 downto 0);
    signal lane_busy : lane_busy_t;
    signal lane_work_pending : std_logic_vector(N_LANES - 1 downto 0);
    signal cnn_input_busy_adc : std_logic;
    signal cnn_work_pending_cnn : std_logic;

    signal lane_score : score_arr_t;
    signal lane_thresh : score_arr_t;
    signal lane_result_chunk : chunk_id_arr_t;
    signal lane_result_start_offset : beat_offset_arr_t;
    signal lane_result_timestamp : timestamp_arr_t;
    signal lane_result_trigger_offset : beat_offset_arr_t;
    signal lane_valid : std_logic_vector(N_LANES - 1 downto 0);
    signal lane_ready : std_logic_vector(N_LANES - 1 downto 0);

    signal result_valid, result_ready : std_logic;
    signal result_request : event_request_t;
    signal result_arbiter_busy : std_logic;
begin
    u_RST_ADC : entity work.RESET_SYNC
        port map (CLK => CLK_ADC, RST_ASYNC => RST, RST_SYNC => rst_adc);
    u_RST_CNN : entity work.RESET_SYNC
        port map (CLK => CLK_CNN, RST_ASYNC => RST, RST_SYNC => rst_cnn);

    u_LIVE_DISTRIBUTOR : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC         => CLK_ADC,
            RST             => rst_adc,
            DATA_STR        => DATA_STR,
            ADC_DATA4       => ADC_DATA4,
            ENABLE          => live_ai_enable,
            LANE_BUSY       => lane_busy,
            LANE_WE         => live_lane_we,
            BATCH_DATA      => live_batch_data,
            CHUNK_ID        => live_chunk_id,
            CHUNK_TIMESTAMP => live_timestamp,
            CHUNK_OVERFLOW  => chunk_overflow_i
        );

    lane_we <= live_lane_we or gated_lane_we;
    lane_batch_data <= gated_batch_data when
        gated_lane_we /= (gated_lane_we'range => '0') else live_batch_data;
    lane_start_chunk <= gated_start_chunk when
        gated_lane_we /= (gated_lane_we'range => '0') else live_chunk_id;
    lane_start_offset_common <= gated_start_offset when
        gated_lane_we /= (gated_lane_we'range => '0') else (others => '0');
    lane_timestamp_common <= gated_timestamp when
        gated_lane_we /= (gated_lane_we'range => '0') else live_timestamp;
    lane_trigger_offset_common <= gated_trigger_offset when
        gated_lane_we /= (gated_lane_we'range => '0') else (others => '0');
    lane_thresh_common <= gated_thresh when
        gated_lane_we /= (gated_lane_we'range => '0') else CNN_THRESH;

    gen_lanes : for lane_idx in 0 to N_LANES - 1 generate
        u_LANE : entity work.CNN_CORE_LANE
            generic map (LANE_ID => lane_idx)
            port map (
                CLK_ADC            => CLK_ADC,
                CLK_CNN            => CLK_CNN,
                RST_ASYNC          => RST,
                RST_ADC            => rst_adc,
                RST_CNN            => rst_cnn,
                WR_EN              => lane_we(lane_idx),
                BATCH_DATA         => lane_batch_data,
                CHUNK_ID           => lane_start_chunk,
                CHUNK_TIMESTAMP    => lane_timestamp_common,
                WORK_START_OFFSET  => lane_start_offset_common,
                WORK_TRIGGER_OFFSET => lane_trigger_offset_common,
                CNN_THRESH         => lane_thresh_common,
                CHUNK_BUSY         => lane_busy(lane_idx),
                WORK_PENDING       => lane_work_pending(lane_idx),
                LANE_SCORE         => lane_score(lane_idx),
                LANE_CHUNK_ID      => lane_result_chunk(lane_idx),
                LANE_TIMESTAMP     => lane_result_timestamp(lane_idx),
                LANE_START_OFFSET  => lane_result_start_offset(lane_idx),
                LANE_TRIGGER_OFFSET => lane_result_trigger_offset(lane_idx),
                LANE_THRESH        => lane_thresh(lane_idx),
                LANE_VALID         => lane_valid(lane_idx),
                LANE_READY         => lane_ready(lane_idx)
            );
    end generate;

    u_RESULT_ARBITER : entity work.CNN_RESULT_ARBITER
        port map (
            CLK                 => CLK_CNN,
            RST                 => rst_cnn,
            LANE_VALID          => lane_valid,
            LANE_READY          => lane_ready,
            LANE_SCORE          => lane_score,
            LANE_THRESH         => lane_thresh,
            LANE_START_CHUNK    => lane_result_chunk,
            LANE_START_OFFSET   => lane_result_start_offset,
            LANE_TIMESTAMP      => lane_result_timestamp,
            LANE_TRIGGER_OFFSET => lane_result_trigger_offset,
            RESULT_VALID        => result_valid,
            RESULT_READY        => result_ready,
            RESULT_REQUEST      => result_request,
            BUSY                => result_arbiter_busy
        );

    process (lane_busy)
        variable any_busy : std_logic;
    begin
        any_busy := '0';
        for lane_idx in 0 to N_LANES - 1 loop
            any_busy := any_busy or lane_busy(lane_idx);
        end loop;
        cnn_input_busy_adc <= any_busy;
    end process;

    cnn_work_pending_cnn <= '0' when
        lane_work_pending = (lane_work_pending'range => '0') and
        result_arbiter_busy = '0' else '1';

    u_MULTIMODE_PATH : entity work.MULTIMODE_EVENT_PATH
        port map (
            CLK_ADC              => CLK_ADC,
            CLK_CNN              => CLK_CNN,
            RST_ADC              => rst_adc,
            RST_CNN              => rst_cnn,
            DATA_STR             => DATA_STR,
            ADC_DATA4            => ADC_DATA4,
            TRIGGER_MODE         => TRIGGER_MODE,
            FORCE_TRIGGER        => FORCE_TRIGGER,
            CNN_THRESH           => CNN_THRESH,
            HL_THRESH            => HL_THRESH,
            HILO_WINDOW          => HILO_WINDOW,
            COINC_WINDOW         => COINC_WINDOW,
            BIN_THR              => BIN_THR,
            CNN_RESULT_VALID     => result_valid,
            CNN_RESULT_READY     => result_ready,
            CNN_RESULT_REQUEST   => result_request,
            CNN_INPUT_BUSY_ADC   => cnn_input_busy_adc,
            CNN_WORK_PENDING_CNN => cnn_work_pending_cnn,
            CNN_CHUNK_OVERFLOW   => chunk_overflow_i,
            LIVE_AI_ENABLE       => live_ai_enable,
            GATED_LANE_BUSY      => lane_busy,
            GATED_LANE_WE        => gated_lane_we,
            GATED_BATCH_DATA     => gated_batch_data,
            GATED_START_CHUNK    => gated_start_chunk,
            GATED_START_OFFSET   => gated_start_offset,
            GATED_TIMESTAMP      => gated_timestamp,
            GATED_TRIGGER_OFFSET => gated_trigger_offset,
            GATED_THRESH         => gated_thresh,
            EVENT_VALID          => EVENT_VALID,
            EVENT_READY          => EVENT_READY,
            EVENT_DATA           => EVENT_DATA,
            EVENT_LAST           => EVENT_LAST,
            EVENT_CHUNK_ID       => EVENT_CHUNK_ID,
            EVENT_TIMESTAMP      => EVENT_TIMESTAMP,
            EVENT_TRIGGER_OFFSET => EVENT_TRIGGER_OFFSET,
            EVENT_SCORE          => EVENT_SCORE,
            ACTIVE_TRIGGER_MODE  => ACTIVE_TRIGGER_MODE,
            MODE_SWITCH_PENDING  => MODE_SWITCH_PENDING,
            INVALID_TRIGGER_MODE => INVALID_TRIGGER_MODE,
            HILO_BLANKING        => HILO_BLANKING,
            HILO_CONFIG_ERROR    => HILO_CONFIG_ERROR,
            EVENT_LOSS           => EVENT_LOSS,
            DROPPED_TRIGGER_COUNT => DROPPED_TRIGGER_COUNT,
            RING_MISS_COUNT       => RING_MISS_COUNT
        );

    CNN_TRIG         <= result_valid and result_ready;
    CNN_OUT_DATA     <= result_request.score;
    CNN_OUT_CHUNK_ID <= result_request.start_address.chunk_id;
    CNN_OUT_VALID    <= result_valid;
    CHUNK_OVERFLOW   <= chunk_overflow_i;
end architecture structural;
