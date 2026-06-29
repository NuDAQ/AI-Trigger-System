library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity EVENT_CAPTURE_PATH is
    port (
        CLK_ADC        : in  std_logic;
        CLK_CNN        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;
        ADC_DATA4      : in  adc_data4_t;

        SCORE_VALID    : in  std_logic;
        SCORE_DATA     : in  std_logic_vector(31 downto 0);
        SCORE_CHUNK_ID : in  chunk_id_t;
        CNN_THRESH     : in  std_logic_vector(31 downto 0);

        EVENT_VALID    : out std_logic;
        EVENT_READY    : in  std_logic;
        EVENT_DATA     : out raw_adc_batch_t;
        EVENT_LAST     : out std_logic;
        EVENT_CHUNK_ID : out chunk_id_t;
        EVENT_SCORE    : out std_logic_vector(31 downto 0)
    );
end entity EVENT_CAPTURE_PATH;

architecture structural of EVENT_CAPTURE_PATH is
    signal chunk_commit      : std_logic;
    signal commit_chunk_id   : chunk_id_t;

    signal trigger_valid_cnn : std_logic;
    signal trigger_score_cnn : std_logic_vector(31 downto 0);
    signal trigger_id_cnn    : chunk_id_t;
    signal trigger_ready_cnn : std_logic;

    signal trigger_valid_adc : std_logic;
    signal trigger_score_adc : std_logic_vector(31 downto 0);
    signal trigger_id_adc    : chunk_id_t;
    signal trigger_ready_adc : std_logic;

    signal rb_rd_en          : std_logic;
    signal rb_rd_chunk_id    : chunk_id_t;
    signal rb_rd_batch_idx   : integer range 0 to N_BATCHES - 1;
    signal rb_rd_data        : raw_adc_batch_t;
    signal rb_rd_valid       : std_logic;
    signal rb_rd_hit         : std_logic;
begin
    u_ring : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK             => CLK_ADC,
            RST             => RST,
            DATA_STR        => DATA_STR,
            ADC_DATA4       => ADC_DATA4,
            CHUNK_COMMIT    => chunk_commit,
            COMMIT_CHUNK_ID => commit_chunk_id,
            RD_EN           => rb_rd_en,
            RD_CHUNK_ID     => rb_rd_chunk_id,
            RD_BATCH_IDX    => rb_rd_batch_idx,
            RD_DATA         => rb_rd_data,
            RD_VALID        => rb_rd_valid,
            RD_HIT          => rb_rd_hit
        );

    u_decision : entity work.TRIGGER_DECISION
        port map (
            CLK              => CLK_CNN,
            RST              => RST,
            SCORE_VALID      => SCORE_VALID,
            SCORE_DATA       => SCORE_DATA,
            SCORE_CHUNK_ID   => SCORE_CHUNK_ID,
            CNN_THRESH       => CNN_THRESH,
            TRIGGER_VALID    => trigger_valid_cnn,
            TRIGGER_SCORE    => trigger_score_cnn,
            TRIGGER_CHUNK_ID => trigger_id_cnn
        );

    u_trigger_cdc : entity work.TRIGGER_CDC_FIFO
        port map (
            WR_CLK      => CLK_CNN,
            WR_RST      => RST,
            WR_VALID    => trigger_valid_cnn,
            WR_READY    => trigger_ready_cnn,
            WR_CHUNK_ID => trigger_id_cnn,
            WR_SCORE    => trigger_score_cnn,
            RD_CLK      => CLK_ADC,
            RD_RST      => RST,
            RD_VALID    => trigger_valid_adc,
            RD_READY    => trigger_ready_adc,
            RD_CHUNK_ID => trigger_id_adc,
            RD_SCORE    => trigger_score_adc
        );

    u_capture : entity work.EVENT_CAPTURE_CTRL
        port map (
            CLK              => CLK_ADC,
            RST              => RST,
            CHUNK_COMMIT     => chunk_commit,
            COMMIT_CHUNK_ID  => commit_chunk_id,
            TRIGGER_VALID    => trigger_valid_adc,
            TRIGGER_CHUNK_ID => trigger_id_adc,
            TRIGGER_SCORE    => trigger_score_adc,
            RB_RD_EN         => rb_rd_en,
            RB_RD_CHUNK_ID   => rb_rd_chunk_id,
            RB_RD_BATCH_IDX  => rb_rd_batch_idx,
            RB_RD_DATA       => rb_rd_data,
            RB_RD_VALID      => rb_rd_valid,
            RB_RD_HIT        => rb_rd_hit,
            EVENT_VALID      => EVENT_VALID,
            EVENT_READY      => EVENT_READY,
            EVENT_DATA       => EVENT_DATA,
            EVENT_LAST       => EVENT_LAST,
            EVENT_CHUNK_ID   => EVENT_CHUNK_ID,
            EVENT_SCORE      => EVENT_SCORE
        );

    trigger_ready_adc <= '1';
end architecture structural;
