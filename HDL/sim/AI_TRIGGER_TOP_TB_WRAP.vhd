-- =============================================================================
-- AI_TRIGGER_TOP_TB_WRAP.vhd
-- Simulation-only VHDL wrapper for tb_ai_trigger_top.sv (mixed-language bridge).
--
-- Vivado xsim cannot connect a SystemVerilog signal to a VHDL port of a
-- user-defined composite type (adc_data4_t).  This wrapper exposes a flat
-- std_logic_vector(767 downto 0) instead (4 ch * 16 samples * 12 bits = 768)
-- and unpacks it to adc_data4_t before driving AI_TRIGGER_TOP.
--
-- Bit packing (must match the SV testbench):
--   ADC_DATA4_FLAT[(ch*16 + s)*12 +: 12]  <->  ADC_DATA4(ch)(s)
--   ch = 0..3,  s = 0..15
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_TOP_TB_WRAP is
    port (
        CLK_ADC         : in  std_logic;
        CLK_CNN         : in  std_logic;
        RST             : in  std_logic;
        DATA_STR        : in  std_logic;
        ADC_DATA4_FLAT  : in  std_logic_vector(767 downto 0);  -- 4*16*12 = 768
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
        DROPPED_TRIGGER_COUNT : out std_logic_vector(31 downto 0);
        RING_MISS_COUNT       : out std_logic_vector(31 downto 0);
        CHUNK_OVERFLOW  : out std_logic
    );
end entity AI_TRIGGER_TOP_TB_WRAP;

architecture rtl of AI_TRIGGER_TOP_TB_WRAP is

    signal adc_internal : adc_data4_t;
    signal cnn_out_chunk_id_i : chunk_id_t;
    signal event_chunk_id_i : chunk_id_t;
    signal event_timestamp_i : timestamp_t;
    signal dropped_trigger_count_i : unsigned(31 downto 0);
    signal ring_miss_count_i : unsigned(31 downto 0);

begin

    -- Unpack flat vector into adc_data4_t.
    -- ADC_DATA4_FLAT[(ch*16+s)*12 +: 12] -> adc_data4_t(ch)(s)
    gen_ch : for ch in 0 to N_CH-1 generate
        gen_s : for s in 0 to N_BATCH_S-1 generate
            adc_internal(ch)(s) <=
                ADC_DATA4_FLAT((ch * N_BATCH_S + s) * 12 + 11 downto
                               (ch * N_BATCH_S + s) * 12);
        end generate;
    end generate;

    u_DUT : entity work.AI_TRIGGER_TOP
        port map (
            CLK_ADC        => CLK_ADC,
            CLK_CNN        => CLK_CNN,
            RST            => RST,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => adc_internal,
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
    DROPPED_TRIGGER_COUNT <= std_logic_vector(dropped_trigger_count_i);
    RING_MISS_COUNT <= std_logic_vector(ring_miss_count_i);

end architecture rtl;
