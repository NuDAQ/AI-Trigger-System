library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;
use work.AI_TRIGGER_PKG.all;

entity MULTIMODE_EVENT_PATH is
    port (
        CLK_ADC              : in  std_logic;
        CLK_CNN              : in  std_logic;
        RST_ADC              : in  std_logic;
        RST_CNN              : in  std_logic;
        DATA_STR             : in  std_logic;
        ADC_DATA4            : in  adc_data4_t;

        TRIGGER_MODE         : in  std_logic_vector(3 downto 0);
        FORCE_TRIGGER        : in  std_logic;
        CNN_THRESH           : in  std_logic_vector(31 downto 0);
        HL_THRESH            : in  std_logic_vector(11 downto 0);
        HILO_WINDOW          : in  std_logic_vector(4 downto 0);
        COINC_WINDOW         : in  std_logic_vector(5 downto 0);
        BIN_THR              : in  std_logic_vector(3 downto 0);

        CNN_RESULT_VALID     : in  std_logic;
        CNN_RESULT_READY     : out std_logic;
        CNN_RESULT_REQUEST   : in  event_request_t;
        CNN_INPUT_BUSY_ADC   : in  std_logic;
        CNN_WORK_PENDING_CNN : in  std_logic;
        CNN_CHUNK_OVERFLOW   : in  std_logic;
        LIVE_AI_ENABLE       : out std_logic;

        GATED_LANE_BUSY      : in  lane_busy_t;
        GATED_LANE_WE        : out std_logic_vector(N_LANES - 1 downto 0);
        GATED_BATCH_DATA     : out std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
        GATED_START_CHUNK    : out chunk_id_t;
        GATED_START_OFFSET   : out beat_offset_t;
        GATED_TIMESTAMP      : out timestamp_t;
        GATED_TRIGGER_OFFSET : out beat_offset_t;
        GATED_THRESH         : out std_logic_vector(31 downto 0);

        EVENT_VALID          : out std_logic;
        EVENT_READY          : in  std_logic;
        EVENT_DATA           : out raw_adc_batch_t;
        EVENT_LAST           : out std_logic;
        EVENT_CHUNK_ID       : out chunk_id_t;
        EVENT_TIMESTAMP      : out timestamp_t;
        EVENT_TRIGGER_OFFSET : out beat_offset_t;
        EVENT_SCORE          : out std_logic_vector(31 downto 0);

        ACTIVE_TRIGGER_MODE  : out std_logic_vector(3 downto 0);
        MODE_SWITCH_PENDING  : out std_logic;
        INVALID_TRIGGER_MODE : out std_logic;
        HILO_BLANKING        : out std_logic;
        HILO_CONFIG_ERROR    : out std_logic;
        EVENT_LOSS           : out std_logic;
        DROPPED_TRIGGER_COUNT : out unsigned(31 downto 0);
        RING_MISS_COUNT       : out unsigned(31 downto 0)
    );
end entity MULTIMODE_EVENT_PATH;

architecture structural of MULTIMODE_EVENT_PATH is
    signal active_mode, active_mode_i : std_logic_vector(3 downto 0);
    signal mode_start, accept_new_work : std_logic;
    signal mode_pending_i, invalid_mode_i : std_logic;
    signal path_idle : std_logic;

    signal chunk_commit : std_logic;
    signal commit_chunk_id, write_chunk_id : chunk_id_t;
    signal commit_timestamp, write_timestamp : timestamp_t;
    signal write_beat_offset : beat_offset_t;

    signal shared_check_chunk : chunk_id_t;
    signal shared_check_offset : beat_offset_t;
    signal shared_check_present, shared_check_protected, shared_check_expired : std_logic;
    signal shared_rd_en : std_logic;
    signal shared_rd_chunk : chunk_id_t;
    signal shared_rd_idx : integer range 0 to N_BATCHES - 1;
    signal shared_rd_data : raw_adc_batch_t;
    signal shared_rd_valid, shared_rd_hit : std_logic;

    signal housekeeping_valid, housekeeping_ready : std_logic;
    signal housekeeping_request : event_request_t;
    signal housekeeping_busy, housekeeping_loss : std_logic;
    signal housekeeping_event_finished, housekeeping_request_failed : std_logic;

    signal hl_adapter_enable, hl_adapter_busy, hl_data_str : std_logic;
    signal hl_adc_data4 : work.PRE_TRIGGER_pkg.adc_data4_type;
    signal hl_anchor_chunk : chunk_id_t;
    signal hl_anchor_offset : beat_offset_t;
    signal hl_anchor_time : timestamp_t;
    signal hilo_event_valid, hilo_event_ready : std_logic;
    signal hilo_event_request : event_request_t;
    signal gated_work_valid, gated_work_ready : std_logic;
    signal gated_work : event_request_t;
    signal hilo_busy, hilo_blanking_i, hilo_config_error_i, hilo_loss : std_logic;
    signal hilo_event_finished, hilo_request_failed : std_logic;

    signal gated_check_chunk : chunk_id_t;
    signal gated_check_offset : beat_offset_t;
    signal gated_check_present, gated_check_protected, gated_check_expired : std_logic;
    signal gated_ring_request, gated_ring_grant, gated_ring_done : std_logic;
    signal gated_rd_en : std_logic;
    signal gated_rd_chunk : chunk_id_t;
    signal gated_rd_idx : integer range 0 to N_BATCHES - 1;
    signal gated_rd_valid, gated_rd_hit : std_logic;
    signal gated_busy, gated_loss : std_logic;

    signal cnn_cdc_wr_busy : std_logic;
    signal cnn_cdc_wr_busy_src : std_logic_vector(0 downto 0);
    signal cnn_work_pending_src : std_logic_vector(0 downto 0);
    signal cnn_cdc_wr_busy_adc : std_logic_vector(0 downto 0);
    signal cnn_work_pending_adc : std_logic_vector(0 downto 0);
    signal cnn_request_valid_adc, cnn_request_ready_adc : std_logic;
    signal cnn_request_adc : event_request_t;

    signal recorder_request_valid, recorder_request_ready : std_logic;
    signal recorder_request : event_request_t;
    signal recorder_check_valid : std_logic;
    signal recorder_check_chunk : chunk_id_t;
    signal recorder_check_offset : beat_offset_t;
    signal recorder_check_present, recorder_check_protected, recorder_check_expired : std_logic;
    signal recorder_ring_request, recorder_ring_grant : std_logic;
    signal recorder_ring_done, recorder_ring_continue, recorder_owner_active : std_logic;
    signal recorder_rd_en : std_logic;
    signal recorder_rd_chunk : chunk_id_t;
    signal recorder_rd_idx : integer range 0 to N_BATCHES - 1;
    signal recorder_rd_valid, recorder_rd_hit : std_logic;
    signal recorder_valid, recorder_ready : std_logic;
    signal recorder_data : raw_adc_batch_t;
    signal recorder_last : std_logic;
    signal recorder_chunk_id : chunk_id_t;
    signal recorder_timestamp : timestamp_t;
    signal recorder_trigger_offset : beat_offset_t;
    signal recorder_score : std_logic_vector(31 downto 0);
    signal recorder_busy, recorder_done, recorder_loss : std_logic;
    signal ring_miss_count_i : unsigned(31 downto 0);

    signal event_credit, event_fifo_empty : std_logic;
    signal event_loss_r : std_logic := '0';
    signal dropped_count_r : unsigned(31 downto 0) := (others => '0');
begin
    housekeeping_event_finished <= recorder_done when
        active_mode = TRIGGER_MODE_EXTERNAL else '0';
    housekeeping_request_failed <= recorder_loss when
        active_mode = TRIGGER_MODE_EXTERNAL else '0';
    hilo_event_finished <= recorder_done when
        active_mode = TRIGGER_MODE_HILO else '0';
    hilo_request_failed <= recorder_loss when
        active_mode = TRIGGER_MODE_HILO else '0';
    cnn_cdc_wr_busy_src(0) <= cnn_cdc_wr_busy;
    cnn_work_pending_src(0) <= CNN_WORK_PENDING_CNN;

    u_RING : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK                  => CLK_ADC,
            RST                  => RST_ADC,
            DATA_STR             => DATA_STR,
            ADC_DATA4            => ADC_DATA4,
            CHUNK_COMMIT         => chunk_commit,
            COMMIT_CHUNK_ID      => commit_chunk_id,
            COMMIT_TIMESTAMP     => commit_timestamp,
            WRITE_CHUNK_ID       => write_chunk_id,
            WRITE_BEAT_OFFSET    => write_beat_offset,
            WRITE_TIMESTAMP      => write_timestamp,
            CHECK_START_CHUNK_ID => shared_check_chunk,
            CHECK_START_OFFSET   => shared_check_offset,
            CHECK_PRESENT        => shared_check_present,
            CHECK_PROTECTED      => shared_check_protected,
            CHECK_EXPIRED        => shared_check_expired,
            RD_EN                => shared_rd_en,
            RD_CHUNK_ID          => shared_rd_chunk,
            RD_BATCH_IDX         => shared_rd_idx,
            RD_DATA              => shared_rd_data,
            RD_VALID             => shared_rd_valid,
            RD_HIT               => shared_rd_hit
        );

    u_MODE : entity work.TRIGGER_MODE_CTRL
        port map (
            CLK                 => CLK_ADC,
            RST                 => RST_ADC,
            REQUESTED_MODE      => TRIGGER_MODE,
            CHUNK_BOUNDARY      => chunk_commit,
            PATH_IDLE           => path_idle,
            ACTIVE_MODE         => active_mode_i,
            MODE_SWITCH_PENDING => mode_pending_i,
            INVALID_REQUEST     => invalid_mode_i,
            ACCEPT_NEW_WORK     => accept_new_work,
            MODE_START          => mode_start
        );
    active_mode <= active_mode_i;

    u_HOUSEKEEPING : entity work.HOUSEKEEPING_TRIGGER_CTRL
        port map (
            CLK              => CLK_ADC,
            RST              => RST_ADC,
            ACTIVE_MODE      => active_mode,
            MODE_START       => mode_start,
            ACCEPT_NEW_WORK  => accept_new_work,
            DATA_STR         => DATA_STR,
            WRITE_CHUNK_ID   => write_chunk_id,
            WRITE_BEAT_OFFSET => write_beat_offset,
            WRITE_TIMESTAMP  => write_timestamp,
            CHUNK_COMMIT     => chunk_commit,
            COMMIT_CHUNK_ID  => commit_chunk_id,
            COMMIT_TIMESTAMP => commit_timestamp,
            FORCE_TRIGGER    => FORCE_TRIGGER,
            REQUEST_VALID    => housekeeping_valid,
            REQUEST_READY    => housekeeping_ready,
            REQUEST_VALUE    => housekeeping_request,
            EVENT_FINISHED   => housekeeping_event_finished,
            REQUEST_FAILED   => housekeeping_request_failed,
            BUSY             => housekeeping_busy,
            EVENT_LOSS_PULSE => housekeeping_loss
        );

    hl_adapter_enable <= accept_new_work when
        active_mode = TRIGGER_MODE_HILO or active_mode = TRIGGER_MODE_HILO_AI
        else '0';
    u_HILO_ADAPTER : entity work.HILO_INPUT_ADAPTER
        port map (
            CLK               => CLK_ADC,
            RST               => RST_ADC,
            MODE_START        => mode_start,
            ENABLE            => hl_adapter_enable,
            DATA_STR          => DATA_STR,
            ADC_DATA4         => ADC_DATA4,
            WRITE_CHUNK_ID    => write_chunk_id,
            WRITE_BEAT_OFFSET => write_beat_offset,
            WRITE_TIMESTAMP   => write_timestamp,
            HL_DATA_STR       => hl_data_str,
            HL_ADC_DATA4      => hl_adc_data4,
            HL_ANCHOR_CHUNK   => hl_anchor_chunk,
            HL_ANCHOR_OFFSET  => hl_anchor_offset,
            HL_ANCHOR_TIME    => hl_anchor_time,
            BUSY              => hl_adapter_busy
        );

    u_HILO : entity work.HILO_TRIGGER_CTRL
        port map (
            CLK                 => CLK_ADC,
            RST                 => RST_ADC,
            ACTIVE_MODE         => active_mode,
            MODE_START          => mode_start,
            HL_DATA_STR         => hl_data_str,
            HL_ADC_DATA4        => hl_adc_data4,
            HL_ANCHOR_CHUNK     => hl_anchor_chunk,
            HL_ANCHOR_OFFSET    => hl_anchor_offset,
            HL_ANCHOR_TIME      => hl_anchor_time,
            HL_THRESH           => HL_THRESH,
            HILO_WINDOW         => HILO_WINDOW,
            COINC_WINDOW        => COINC_WINDOW,
            BIN_THR             => BIN_THR,
            EVENT_REQUEST_VALID => hilo_event_valid,
            EVENT_REQUEST_READY => hilo_event_ready,
            EVENT_REQUEST       => hilo_event_request,
            GATED_WORK_VALID    => gated_work_valid,
            GATED_WORK_READY    => gated_work_ready,
            GATED_WORK          => gated_work,
            EVENT_FINISHED      => hilo_event_finished,
            REQUEST_FAILED      => hilo_request_failed,
            BUSY                => hilo_busy,
            HILO_BLANKING       => hilo_blanking_i,
            HILO_CONFIG_ERROR   => hilo_config_error_i,
            EVENT_LOSS_PULSE    => hilo_loss
        );

    u_GATED_READER : entity work.GATED_CNN_READER
        port map (
            CLK                  => CLK_ADC,
            RST                  => RST_ADC,
            WORK_VALID           => gated_work_valid,
            WORK_READY           => gated_work_ready,
            WORK_VALUE           => gated_work,
            CNN_THRESH           => CNN_THRESH,
            LANE_BUSY            => GATED_LANE_BUSY,
            CHECK_START_CHUNK_ID => gated_check_chunk,
            CHECK_START_OFFSET   => gated_check_offset,
            CHECK_PRESENT        => gated_check_present,
            CHECK_PROTECTED      => gated_check_protected,
            CHECK_EXPIRED        => gated_check_expired,
            RING_REQUEST         => gated_ring_request,
            RING_GRANT           => gated_ring_grant,
            RING_DONE            => gated_ring_done,
            RB_RD_EN             => gated_rd_en,
            RB_RD_CHUNK_ID       => gated_rd_chunk,
            RB_RD_BATCH_IDX      => gated_rd_idx,
            RB_RD_DATA           => shared_rd_data,
            RB_RD_VALID          => gated_rd_valid,
            RB_RD_HIT            => gated_rd_hit,
            LANE_WE              => GATED_LANE_WE,
            BATCH_DATA           => GATED_BATCH_DATA,
            LANE_START_CHUNK     => GATED_START_CHUNK,
            LANE_START_OFFSET    => GATED_START_OFFSET,
            LANE_TIMESTAMP       => GATED_TIMESTAMP,
            LANE_TRIGGER_OFFSET  => GATED_TRIGGER_OFFSET,
            LANE_THRESH          => GATED_THRESH,
            BUSY                 => gated_busy,
            EVENT_LOSS_PULSE     => gated_loss
        );

    u_CNN_REQUEST_CDC : entity work.TRIGGER_CDC_FIFO
        port map (
            WR_CLK            => CLK_CNN,
            WR_RST            => RST_CNN,
            WR_VALID          => CNN_RESULT_VALID,
            WR_READY          => CNN_RESULT_READY,
            WR_BUSY           => cnn_cdc_wr_busy,
            WR_CHUNK_ID       => CNN_RESULT_REQUEST.start_address.chunk_id,
            WR_SCORE          => CNN_RESULT_REQUEST.score,
            WR_TIMESTAMP      => CNN_RESULT_REQUEST.event_timestamp,
            WR_START_OFFSET   => CNN_RESULT_REQUEST.start_address.beat_offset,
            WR_TRIGGER_OFFSET => CNN_RESULT_REQUEST.trigger_offset,
            RD_CLK            => CLK_ADC,
            RD_RST            => RST_ADC,
            RD_VALID          => cnn_request_valid_adc,
            RD_READY          => cnn_request_ready_adc,
            RD_CHUNK_ID       => cnn_request_adc.start_address.chunk_id,
            RD_SCORE          => cnn_request_adc.score,
            RD_TIMESTAMP      => cnn_request_adc.event_timestamp,
            RD_START_OFFSET   => cnn_request_adc.start_address.beat_offset,
            RD_TRIGGER_OFFSET => cnn_request_adc.trigger_offset
        );

    u_CNN_BUSY_SYNC : xpm_cdc_array_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 0, SIM_ASSERT_CHK => 0,
                     SRC_INPUT_REG => 1, WIDTH => 1)
        port map (src_clk => CLK_CNN, src_in => cnn_cdc_wr_busy_src,
                  dest_clk => CLK_ADC, dest_out => cnn_cdc_wr_busy_adc);
    u_CNN_WORK_SYNC : xpm_cdc_array_single
        generic map (DEST_SYNC_FF => 2, INIT_SYNC_FF => 0, SIM_ASSERT_CHK => 0,
                     SRC_INPUT_REG => 1, WIDTH => 1)
        port map (src_clk => CLK_CNN, src_in => cnn_work_pending_src,
                  dest_clk => CLK_ADC, dest_out => cnn_work_pending_adc);

    process (
        active_mode,
        housekeeping_valid,
        housekeeping_request,
        hilo_event_valid,
        hilo_event_request,
        cnn_request_valid_adc,
        cnn_request_adc,
        recorder_request_ready
    )
    begin
        recorder_request_valid <= '0';
        recorder_request       <= NULL_EVENT_REQUEST;
        housekeeping_ready     <= '0';
        hilo_event_ready       <= '0';
        cnn_request_ready_adc  <= '0';
        if active_mode = TRIGGER_MODE_CAPTURE_ALL or
           active_mode = TRIGGER_MODE_EXTERNAL then
            recorder_request_valid <= housekeeping_valid;
            recorder_request       <= housekeeping_request;
            housekeeping_ready     <= recorder_request_ready;
        elsif active_mode = TRIGGER_MODE_HILO then
            recorder_request_valid <= hilo_event_valid;
            recorder_request       <= hilo_event_request;
            hilo_event_ready       <= recorder_request_ready;
        elsif active_mode = TRIGGER_MODE_AI or
              active_mode = TRIGGER_MODE_HILO_AI then
            recorder_request_valid <= cnn_request_valid_adc;
            recorder_request       <= cnn_request_adc;
            cnn_request_ready_adc  <= recorder_request_ready;
        end if;
    end process;

    u_RECORDER : entity work.EVENT_RECORDER
        port map (
            CLK                  => CLK_ADC,
            RST                  => RST_ADC,
            REQUEST_VALID        => recorder_request_valid,
            REQUEST_READY        => recorder_request_ready,
            REQUEST_VALUE        => recorder_request,
            CHECK_VALID          => recorder_check_valid,
            CHECK_START_CHUNK_ID => recorder_check_chunk,
            CHECK_START_OFFSET   => recorder_check_offset,
            CHECK_PRESENT        => recorder_check_present,
            CHECK_PROTECTED      => recorder_check_protected,
            CHECK_EXPIRED        => recorder_check_expired,
            RING_REQUEST         => recorder_ring_request,
            RING_GRANT           => recorder_ring_grant,
            RING_DONE            => recorder_ring_done,
            RING_CONTINUE        => recorder_ring_continue,
            RING_OWNER_ACTIVE    => recorder_owner_active,
            RB_RD_EN             => recorder_rd_en,
            RB_RD_CHUNK_ID       => recorder_rd_chunk,
            RB_RD_BATCH_IDX      => recorder_rd_idx,
            RB_RD_DATA           => shared_rd_data,
            RB_RD_VALID          => recorder_rd_valid,
            RB_RD_HIT            => recorder_rd_hit,
            EVENT_CREDIT         => event_credit,
            EVENT_VALID          => recorder_valid,
            EVENT_READY          => recorder_ready,
            EVENT_DATA           => recorder_data,
            EVENT_LAST           => recorder_last,
            EVENT_CHUNK_ID       => recorder_chunk_id,
            EVENT_TIMESTAMP      => recorder_timestamp,
            EVENT_TRIGGER_OFFSET => recorder_trigger_offset,
            EVENT_SCORE          => recorder_score,
            BUSY                 => recorder_busy,
            EVENT_DONE_PULSE     => recorder_done,
            EVENT_LOSS_PULSE     => recorder_loss,
            RING_MISS_COUNT      => ring_miss_count_i
        );

    u_RING_ARBITER : entity work.RING_READ_ARBITER
        port map (
            CLK                    => CLK_ADC,
            RST                    => RST_ADC,
            EVENT_CHECK_VALID      => recorder_check_valid,
            EVENT_CHECK_CHUNK      => recorder_check_chunk,
            EVENT_CHECK_OFFSET     => recorder_check_offset,
            EVENT_CHECK_PRESENT    => recorder_check_present,
            EVENT_CHECK_PROTECTED  => recorder_check_protected,
            EVENT_CHECK_EXPIRED    => recorder_check_expired,
            GATED_CHECK_VALID      => gated_work_valid,
            GATED_CHECK_CHUNK      => gated_check_chunk,
            GATED_CHECK_OFFSET     => gated_check_offset,
            GATED_CHECK_PRESENT    => gated_check_present,
            GATED_CHECK_PROTECTED  => gated_check_protected,
            GATED_CHECK_EXPIRED    => gated_check_expired,
            SHARED_CHECK_CHUNK     => shared_check_chunk,
            SHARED_CHECK_OFFSET    => shared_check_offset,
            SHARED_CHECK_PRESENT   => shared_check_present,
            SHARED_CHECK_PROTECTED => shared_check_protected,
            SHARED_CHECK_EXPIRED   => shared_check_expired,
            EVENT_REQUEST          => recorder_ring_request,
            EVENT_GRANT            => recorder_ring_grant,
            EVENT_DONE             => recorder_ring_done,
            EVENT_CONTINUE         => recorder_ring_continue,
            EVENT_OWNER_ACTIVE     => recorder_owner_active,
            GATED_REQUEST          => gated_ring_request,
            GATED_GRANT            => gated_ring_grant,
            GATED_DONE             => gated_ring_done,
            EVENT_RD_EN            => recorder_rd_en,
            EVENT_RD_CHUNK         => recorder_rd_chunk,
            EVENT_RD_IDX           => recorder_rd_idx,
            EVENT_RD_VALID         => recorder_rd_valid,
            EVENT_RD_HIT           => recorder_rd_hit,
            GATED_RD_EN            => gated_rd_en,
            GATED_RD_CHUNK         => gated_rd_chunk,
            GATED_RD_IDX           => gated_rd_idx,
            GATED_RD_VALID         => gated_rd_valid,
            GATED_RD_HIT           => gated_rd_hit,
            SHARED_RD_EN           => shared_rd_en,
            SHARED_RD_CHUNK        => shared_rd_chunk,
            SHARED_RD_IDX          => shared_rd_idx,
            SHARED_RD_DATA         => shared_rd_data,
            SHARED_RD_VALID        => shared_rd_valid,
            SHARED_RD_HIT          => shared_rd_hit
        );

    u_EVENT_FIFO : entity work.EVENT_OUTPUT_FIFO
        port map (
            CLK               => CLK_ADC,
            RST               => RST_ADC,
            WR_VALID          => recorder_valid,
            WR_READY          => recorder_ready,
            WR_DATA           => recorder_data,
            WR_LAST           => recorder_last,
            WR_CHUNK_ID       => recorder_chunk_id,
            WR_TIMESTAMP      => recorder_timestamp,
            WR_TRIGGER_OFFSET => recorder_trigger_offset,
            WR_SCORE          => recorder_score,
            EVENT_CREDIT      => event_credit,
            FIFO_EMPTY        => event_fifo_empty,
            RD_VALID          => EVENT_VALID,
            RD_READY          => EVENT_READY,
            RD_DATA           => EVENT_DATA,
            RD_LAST           => EVENT_LAST,
            RD_CHUNK_ID       => EVENT_CHUNK_ID,
            RD_TIMESTAMP      => EVENT_TIMESTAMP,
            RD_TRIGGER_OFFSET => EVENT_TRIGGER_OFFSET,
            RD_SCORE          => EVENT_SCORE
        );

    path_idle <= '1' when housekeeping_busy = '0' and hl_adapter_busy = '0' and
        hilo_busy = '0' and gated_busy = '0' and recorder_busy = '0' and
        event_fifo_empty = '1' and CNN_INPUT_BUSY_ADC = '0' and
        cnn_work_pending_adc(0) = '0' and cnn_cdc_wr_busy_adc(0) = '0' and
        cnn_request_valid_adc = '0' else '0';

    LIVE_AI_ENABLE <= '1' when active_mode = TRIGGER_MODE_AI and
        accept_new_work = '1' else '0';

    process (CLK_ADC)
        variable loss_count : integer range 0 to 5;
    begin
        if rising_edge(CLK_ADC) then
            if RST_ADC = '1' then
                event_loss_r   <= '0';
                dropped_count_r <= (others => '0');
            else
                loss_count := 0;
                if housekeeping_loss = '1' then loss_count := loss_count + 1; end if;
                if hilo_loss = '1' then loss_count := loss_count + 1; end if;
                if gated_loss = '1' then loss_count := loss_count + 1; end if;
                if recorder_loss = '1' then loss_count := loss_count + 1; end if;
                if CNN_CHUNK_OVERFLOW = '1' then loss_count := loss_count + 1; end if;
                if loss_count > 0 then
                    event_loss_r <= '1';
                    dropped_count_r <= dropped_count_r +
                        to_unsigned(loss_count, dropped_count_r'length);
                end if;
            end if;
        end if;
    end process;

    ACTIVE_TRIGGER_MODE  <= active_mode;
    MODE_SWITCH_PENDING  <= mode_pending_i;
    INVALID_TRIGGER_MODE <= invalid_mode_i;
    HILO_BLANKING        <= hilo_blanking_i;
    HILO_CONFIG_ERROR    <= hilo_config_error_i;
    EVENT_LOSS           <= event_loss_r;
    DROPPED_TRIGGER_COUNT <= dropped_count_r;
    RING_MISS_COUNT       <= ring_miss_count_i;
end architecture structural;
