-- =============================================================================
-- AI_TRIGGER_TOP
-- DAQ-facing out-of-context top.
--
-- Public interface:
--   * CLK_ADC domain ADC stream: DATA_STR + flat 384-bit ADC_DATA
--   * CLK_CNN domain CNN inference clock
--   * CLK_ADC domain runtime trigger configuration and operational status
--   * CLK_ADC domain event stream: waveform batch, LAST, timestamp, and anchor
--
-- CNN_THRESH is kept as a 32-bit DAQ-friendly word.  The core uses only
-- bits [21:0] as signed ap_fixed<22,11> raw threshold.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_TOP is
    port (
        CLK_ADC        : in  std_logic;
        CLK_CNN        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;
        ADC_DATA       : in  std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);

        TRIGGER_MODE   : in  std_logic_vector(3 downto 0);
        FORCE_TRIGGER  : in  std_logic;
        CNN_THRESH     : in  std_logic_vector(31 downto 0);
        HL_THRESH      : in  std_logic_vector(11 downto 0);
        HILO_WINDOW    : in  std_logic_vector(4 downto 0);
        COINC_WINDOW   : in  std_logic_vector(5 downto 0);
        BIN_THR        : in  std_logic_vector(3 downto 0);

        EVENT_VALID    : out std_logic;
        EVENT_READY    : in  std_logic;
        EVENT_DATA     : out std_logic_vector(RAW_ADC_BATCH_WIDTH - 1 downto 0);
        EVENT_LAST     : out std_logic;
        EVENT_TIMESTAMP : out std_logic_vector(TIMESTAMP_WIDTH - 1 downto 0);
        EVENT_TRIGGER_OFFSET : out std_logic_vector(BEAT_OFFSET_WIDTH - 1 downto 0);

        ACTIVE_TRIGGER_MODE  : out std_logic_vector(3 downto 0);
        MODE_SWITCH_PENDING  : out std_logic;
        INVALID_TRIGGER_MODE : out std_logic;
        HILO_BLANKING        : out std_logic;
        HILO_CONFIG_ERROR    : out std_logic;
        EVENT_LOSS           : out std_logic
    );
end entity AI_TRIGGER_TOP;

architecture structural of AI_TRIGGER_TOP is
    signal adc_data4 : adc_data4_t;
    signal event_timestamp_i : timestamp_t;
    signal event_trigger_offset_i : beat_offset_t;
begin
    gen_ch : for ch in 0 to N_ADC_CH-1 generate
        gen_s : for s in 0 to N_BATCH_S-1 generate
            adc_data4(ch)(s) <=
                ADC_DATA((ch * N_BATCH_S + s) * 12 + 11 downto
                         (ch * N_BATCH_S + s) * 12);
        end generate;
    end generate;

    u_CORE : entity work.AI_TRIGGER_CORE
        port map (
            CLK_ADC        => CLK_ADC,
            CLK_CNN        => CLK_CNN,
            RST            => RST,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => adc_data4,
            TRIGGER_MODE   => TRIGGER_MODE,
            FORCE_TRIGGER  => FORCE_TRIGGER,
            CNN_THRESH     => CNN_THRESH,
            HL_THRESH      => HL_THRESH,
            HILO_WINDOW    => HILO_WINDOW,
            COINC_WINDOW   => COINC_WINDOW,
            BIN_THR        => BIN_THR,
            CNN_TRIG       => open,
            CNN_OUT_DATA   => open,
            CNN_OUT_CHUNK_ID => open,
            CNN_OUT_VALID  => open,
            EVENT_VALID    => EVENT_VALID,
            EVENT_READY    => EVENT_READY,
            EVENT_DATA     => EVENT_DATA,
            EVENT_LAST     => EVENT_LAST,
            EVENT_CHUNK_ID => open,
            EVENT_TIMESTAMP => event_timestamp_i,
            EVENT_TRIGGER_OFFSET => event_trigger_offset_i,
            EVENT_SCORE    => open,
            ACTIVE_TRIGGER_MODE => ACTIVE_TRIGGER_MODE,
            MODE_SWITCH_PENDING => MODE_SWITCH_PENDING,
            INVALID_TRIGGER_MODE => INVALID_TRIGGER_MODE,
            HILO_BLANKING => HILO_BLANKING,
            HILO_CONFIG_ERROR => HILO_CONFIG_ERROR,
            EVENT_LOSS => EVENT_LOSS,
            DROPPED_TRIGGER_COUNT => open,
            RING_MISS_COUNT       => open,
            CHUNK_OVERFLOW => open
        );

    EVENT_TIMESTAMP <= std_logic_vector(event_timestamp_i);
    EVENT_TRIGGER_OFFSET <= std_logic_vector(event_trigger_offset_i);
end architecture structural;
