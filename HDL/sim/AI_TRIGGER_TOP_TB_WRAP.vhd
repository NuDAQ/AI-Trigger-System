-- =============================================================================
-- AI_TRIGGER_TOP_TB_WRAP.vhd
-- Simulation-only VHDL wrapper for tb_ai_trigger_top.sv (mixed-language bridge).
--
-- Vivado xsim cannot connect a SystemVerilog signal to a VHDL port of a
-- user-defined composite type (adc_data4_t).  This wrapper exposes a flat
-- std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0) instead
-- (8 ch * 4 samples * 12 bits = 384)
-- and crosses the source-side test stream into AI_TRIGGER_CORE.
--
-- Bit packing (must match the SV testbench):
--   ADC_DATA4_FLAT[(ch*N_BATCH_S + s)*12 +: 12]  <->  ADC_DATA4(ch)(s)
--   ch = 0..7,  s = 0..N_BATCH_S-1
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_TOP_TB_WRAP is
    port (
        CLK_ADC         : in  std_logic;
        ADC_SRC_CLK     : in  std_logic;
        CLK_CNN         : in  std_logic;
        RST             : in  std_logic;
        DATA_STR        : in  std_logic;
        ADC_SRC_READY   : out std_logic;
        ADC_DATA4_FLAT  : in  std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
        CNN_THRESH      : in  std_logic_vector(31 downto 0);
        CNN_TRIG        : out std_logic;
        CNN_OUT_DATA    : out std_logic_vector(31 downto 0);
        CNN_OUT_CHUNK_ID: out std_logic_vector(CHUNK_ID_WIDTH - 1 downto 0);
        CNN_OUT_VALID   : out std_logic;
        EVENT_VALID     : out std_logic;
        EVENT_READY     : in  std_logic;
        EVENT_DATA      : out std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
        EVENT_LAST      : out std_logic;
        EVENT_CHUNK_ID  : out std_logic_vector(CHUNK_ID_WIDTH - 1 downto 0);
        EVENT_TIMESTAMP : out std_logic_vector(TIMESTAMP_WIDTH - 1 downto 0);
        EVENT_SCORE     : out std_logic_vector(31 downto 0);
        ADC_INPUT_OVERFLOW_COUNT : out std_logic_vector(31 downto 0);
        DROPPED_TRIGGER_COUNT : out std_logic_vector(31 downto 0);
        RING_MISS_COUNT       : out std_logic_vector(31 downto 0);
        CHUNK_OVERFLOW  : out std_logic
    );
end entity AI_TRIGGER_TOP_TB_WRAP;

architecture rtl of AI_TRIGGER_TOP_TB_WRAP is

    signal adc_ingest_raw : raw_adc_batch_t;
    signal adc_core       : adc_data4_t;
    signal cnn_out_chunk_id_i : chunk_id_t;
    signal event_chunk_id_i : chunk_id_t;
    signal event_timestamp_i : timestamp_t;
    signal adc_input_overflow_count_i : unsigned(31 downto 0);
    signal dropped_trigger_count_i : unsigned(31 downto 0);
    signal ring_miss_count_i : unsigned(31 downto 0);
    signal data_str_core : std_logic;
    signal rst_adc_src : std_logic := '1';
    signal rst_adc     : std_logic := '1';

begin

    -- Simulation-only source-clock reset and input CDC.  The delivered
    -- AI_TRIGGER_TOP starts after this boundary at CLK_ADC.
    u_RST_ADC_SRC : entity work.RESET_SYNC
        port map (
            CLK       => ADC_SRC_CLK,
            RST_ASYNC => RST,
            RST_SYNC  => rst_adc_src
        );

    u_RST_ADC : entity work.RESET_SYNC
        port map (
            CLK       => CLK_ADC,
            RST_ASYNC => RST,
            RST_SYNC  => rst_adc
        );

    u_ADC_INPUT : entity work.ADC_INPUT_CDC_FIFO
        port map (
            WR_CLK         => ADC_SRC_CLK,
            WR_RST         => rst_adc_src,
            WR_VALID       => DATA_STR,
            WR_READY       => ADC_SRC_READY,
            WR_DATA        => ADC_DATA4_FLAT,
            RD_CLK         => CLK_ADC,
            RD_RST         => rst_adc,
            RD_VALID       => data_str_core,
            RD_READY       => '1',
            RD_DATA        => adc_ingest_raw,
            OVERFLOW_COUNT => adc_input_overflow_count_i
        );

    -- Unpack the CLK_ADC-domain flat vector into adc_data4_t.
    -- adc_ingest_raw[(ch*N_BATCH_S+s)*12 +: 12] -> adc_data4_t(ch)(s)
    gen_ch : for ch in 0 to N_ADC_CH-1 generate
        gen_s : for s in 0 to N_BATCH_S-1 generate
            adc_core(ch)(s) <=
                adc_ingest_raw((ch * N_BATCH_S + s) * 12 + 11 downto
                               (ch * N_BATCH_S + s) * 12);
        end generate;
    end generate;

    u_DUT : entity work.AI_TRIGGER_CORE
        port map (
            CLK_ADC        => CLK_ADC,
            CLK_CNN        => CLK_CNN,
            RST            => RST,
            DATA_STR       => data_str_core,
            ADC_DATA4      => adc_core,
            CNN_THRESH     => CNN_THRESH,
            CNN_TRIG       => CNN_TRIG,
            CNN_OUT_DATA   => CNN_OUT_DATA,
            CNN_OUT_CHUNK_ID => cnn_out_chunk_id_i,
            CNN_OUT_VALID  => CNN_OUT_VALID,
            EVENT_VALID    => EVENT_VALID,
            EVENT_READY    => EVENT_READY,
            EVENT_DATA     => EVENT_DATA,
            EVENT_LAST     => EVENT_LAST,
            EVENT_CHUNK_ID => event_chunk_id_i,
            EVENT_TIMESTAMP => event_timestamp_i,
            EVENT_SCORE    => EVENT_SCORE,
            DROPPED_TRIGGER_COUNT => dropped_trigger_count_i,
            RING_MISS_COUNT       => ring_miss_count_i,
            CHUNK_OVERFLOW => CHUNK_OVERFLOW
        );

    CNN_OUT_CHUNK_ID <= std_logic_vector(cnn_out_chunk_id_i);
    EVENT_CHUNK_ID <= std_logic_vector(event_chunk_id_i);
    EVENT_TIMESTAMP <= std_logic_vector(event_timestamp_i);
    ADC_INPUT_OVERFLOW_COUNT <= std_logic_vector(adc_input_overflow_count_i);
    DROPPED_TRIGGER_COUNT <= std_logic_vector(dropped_trigger_count_i);
    RING_MISS_COUNT <= std_logic_vector(ring_miss_count_i);

end architecture rtl;
