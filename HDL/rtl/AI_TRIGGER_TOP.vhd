-- =============================================================================
-- AI_TRIGGER_TOP
-- Top-level structural wrapper for the 6-lane parallel CNN trigger.
--
-- Instantiates:
--   - ADC_CHUNK_DISTRIBUTOR: accumulates ADC batches, distributes chunks
--                             round-robin to 6 CNN_CORE_LANE instances
--   - CNN_CORE_LANE x 6:     each lane buffers one chunk, runs CNN inference,
--                             and reports score + valid pulse
--
-- Trigger decision (CLK_CNN domain):
--   CNN_TRIG fires for one CLK_CNN cycle when any lane reports
--   a score that exceeds CNN_THRESH (signed comparison, ap_fixed<16,6>).
--
-- CNN_THRESH encoding (ap_fixed<16,6>, raw / 1024 = float score):
--   0.5  -> 16'sd512    1.0 -> 16'sd1024    -0.5 -> 16'sd-512
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity AI_TRIGGER_TOP is
    port (
        -- Clocks and reset
        CLK_ADC      : in  std_logic;
        CLK_CNN      : in  std_logic;
        RST          : in  std_logic;   -- active-high, synchronous to CLK_ADC

        -- ADC input (CLK_ADC domain)
        DATA_STR     : in  std_logic;   -- one pulse per 16-sample batch
        ADC_DATA4    : in  adc_data4_t;

        -- Trigger threshold (static / slow-control)
        CNN_THRESH   : in  std_logic_vector(15 downto 0);  -- ap_fixed<16,6> raw

        -- Trigger output (CLK_CNN domain)
        CNN_TRIG     : out std_logic;   -- 1-cycle pulse: any lane score > CNN_THRESH

        -- Score monitoring (CLK_CNN domain, most recent completed inference)
        CNN_OUT_DATA  : out std_logic_vector(15 downto 0);
        CNN_OUT_VALID : out std_logic;

        -- Overflow status (CLK_ADC domain)
        CHUNK_OVERFLOW : out std_logic  -- sticky: chunk dropped, lane was busy
    );
end entity AI_TRIGGER_TOP;

architecture structural of AI_TRIGGER_TOP is

    -- Distributor -> lanes
    signal lane_we      : std_logic_vector(N_LANES-1 downto 0);
    signal batch_addr   : std_logic_vector(3 downto 0);
    signal batch_data   : std_logic_vector(N_BATCH_S*64-1 downto 0);

    -- Lanes -> distributor
    signal lane_busy    : lane_busy_t;

    -- Lane results (CLK_CNN domain)
    type score_arr_t is array (0 to N_LANES-1) of std_logic_vector(15 downto 0);
    signal lane_score : score_arr_t;
    signal lane_valid : std_logic_vector(N_LANES-1 downto 0);
    signal lane_trig  : std_logic_vector(N_LANES-1 downto 0);

begin

    -- =========================================================================
    -- ADC_CHUNK_DISTRIBUTOR
    -- =========================================================================
    u_DIST : entity work.ADC_CHUNK_DISTRIBUTOR
        port map (
            CLK_ADC        => CLK_ADC,
            RST            => RST,
            DATA_STR       => DATA_STR,
            ADC_DATA4      => ADC_DATA4,
            LANE_BUSY      => lane_busy,
            LANE_WE        => lane_we,
            BATCH_ADDR     => batch_addr,
            BATCH_DATA     => batch_data,
            CHUNK_OVERFLOW => CHUNK_OVERFLOW
        );

    -- =========================================================================
    -- CNN_CORE_LANE x N_LANES
    -- =========================================================================
    gen_lanes : for i in 0 to N_LANES-1 generate
        u_LANE : entity work.CNN_CORE_LANE
            port map (
                CLK_ADC    => CLK_ADC,
                CLK_CNN    => CLK_CNN,
                RST        => RST,
                WR_EN      => lane_we(i),
                BATCH_ADDR => batch_addr,
                BATCH_DATA => batch_data,
                CHUNK_BUSY => lane_busy(i),
                LANE_TRIG  => lane_trig(i),  -- unused placeholder from lane
                LANE_SCORE => lane_score(i),
                LANE_VALID => lane_valid(i)
            );
    end generate;

    -- =========================================================================
    -- Result aggregation (CLK_CNN domain)
    -- Registered comparators, one per lane.  CNN_TRIG = OR of all lane fires.
    -- =========================================================================
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
                    if signed(lane_score(i)) > signed(CNN_THRESH) then
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
