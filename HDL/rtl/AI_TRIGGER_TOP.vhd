-- =============================================================================
-- AI_TRIGGER_TOP
-- Top-level structural wrapper for the parallel CNN trigger.
--
-- Instantiates:
--   - ADC_CHUNK_DISTRIBUTOR: accumulates ADC batches (DATA_STR always high),
--                             distributes chunks round-robin to CNN_CORE_LANE
--   - CNN_CORE_LANE x N_LANES: FIFO buffer + CDC + CNN inference per lane
--
-- Trigger decision (CLK_CNN domain):
--   CNN_TRIG fires for one CLK_CNN cycle when any lane reports a score that
--   exceeds CNN_THRESH.  WRAPPER_TOP returns ap_fixed<9,5> byte-aligned into
--   the low 9 bits of a 16-bit TDATA word, matching its reference testbench:
--   float_score = signed(score[8:0]) / 16.
--
-- CNN_THRESH encoding (ap_fixed<9,5>, raw / 16 = float score):
--   0.5 -> 9'sd8    1.0 -> 9'sd16    -6.0 -> 9'sd-96
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

        DATA_STR       : in  std_logic;   -- always high in normal operation
        ADC_DATA4      : in  adc_data4_t;

        CNN_THRESH     : in  std_logic_vector(15 downto 0);

        CNN_TRIG       : out std_logic;
        CNN_OUT_DATA   : out std_logic_vector(15 downto 0);
        CNN_OUT_VALID  : out std_logic;

        CHUNK_OVERFLOW : out std_logic
    );
end entity AI_TRIGGER_TOP;

architecture structural of AI_TRIGGER_TOP is

    signal lane_we    : std_logic_vector(N_LANES-1 downto 0);
    signal batch_data : std_logic_vector(N_BATCH_S*64-1 downto 0);
    signal lane_busy  : lane_busy_t;

    type score_arr_t is array (0 to N_LANES-1) of std_logic_vector(15 downto 0);
    signal lane_score : score_arr_t;
    signal lane_valid : std_logic_vector(N_LANES-1 downto 0);

begin

    u_DIST : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC        => CLK_ADC,
            RST            => RST,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => ADC_DATA4,
            LANE_BUSY      => lane_busy,
            LANE_WE        => lane_we,
            BATCH_DATA     => batch_data,
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
                RST        => RST,
                WR_EN      => lane_we(i),
                BATCH_DATA => batch_data,
                CHUNK_BUSY => lane_busy(i),
                LANE_SCORE => lane_score(i),
                LANE_VALID => lane_valid(i)
            );
    end generate;

    -- Result aggregation (CLK_CNN): registered comparator per lane, OR result
    process(CLK_CNN)
        variable any_trig  : std_logic;
        variable last_data : std_logic_vector(15 downto 0);
        variable last_valid: std_logic;
    begin
        if rising_edge(CLK_CNN) then
            any_trig   := '0';
            last_data  := (others => '0');
            last_valid := '0';
            for i in 0 to N_LANES-1 loop
                if lane_valid(i) = '1' then
                    last_data  := lane_score(i);
                    last_valid := '1';
                    if signed(lane_score(i)(8 downto 0)) >
                       signed(CNN_THRESH(8 downto 0)) then
                        any_trig := '1';
                    end if;
                end if;
            end loop;
            CNN_TRIG      <= any_trig;
            CNN_OUT_DATA  <= last_data;
            CNN_OUT_VALID <= last_valid;
        end if;
    end process;

end architecture structural;
