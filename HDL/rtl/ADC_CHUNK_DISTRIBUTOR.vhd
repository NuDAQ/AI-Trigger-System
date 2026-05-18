-- =============================================================================
-- ADC_CHUNK_DISTRIBUTOR
-- CLK_ADC domain.
--
-- DATA_STR is asserted every CLK_ADC cycle (continuous 1 Gsps ADC stream).
-- Each cycle carries one 16-sample batch across 4 channels.
-- After N_BATCHES (16) cycles the complete 256-sample chunk is committed to the
-- selected lane via LANE_WE.  The lane counter advances round-robin every chunk.
--
-- CHUNK_BUSY feedback (CLK_ADC domain) comes from each lane's FIFO full signal.
-- If the target lane's FIFO is full when the chunk boundary arrives, the chunk
-- is dropped and CHUNK_OVERFLOW is asserted.
--
-- BATCH_DATA packing (1024-bit = 16 words x 64-bit):
--   word[i] bits [15: 0] = ch0 sample i, sign-extended 12->16 bit
--   word[i] bits [31:16] = ch1 sample i
--   word[i] bits [47:32] = ch2 sample i
--   word[i] bits [63:48] = ch3 sample i
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity ADC_CHUNK_DISTRIBUTOR is
    port (
        CLK_ADC        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;   -- always high in normal operation
        ADC_DATA4      : in  adc_data4_t;

        LANE_BUSY      : in  lane_busy_t; -- FIFO full per lane (CLK_ADC domain)

        LANE_WE        : out std_logic_vector(N_LANES-1 downto 0);
        BATCH_DATA     : out std_logic_vector(N_BATCH_S*64-1 downto 0);

        CHUNK_OVERFLOW : out std_logic
    );
end entity ADC_CHUNK_DISTRIBUTOR;

architecture rtl of ADC_CHUNK_DISTRIBUTOR is

    signal batch_cnt  : integer range 0 to N_BATCHES-1 := 0;
    signal lane_sel   : integer range 0 to N_LANES-1   := 0;
    signal overflow_r : std_logic := '0';
    signal we_r       : std_logic_vector(N_LANES-1 downto 0) := (others => '0');

    signal packed : std_logic_vector(N_BATCH_S*64-1 downto 0);

    function sign_ext(s : std_logic_vector(11 downto 0)) return std_logic_vector is
    begin
        return s(11) & s(11) & s(11) & s(11) & s;
    end function;

begin

    -- -------------------------------------------------------------------------
    -- Combinational packing: 4 ch x 16 samples -> 1024-bit word
    -- -------------------------------------------------------------------------
    gen_pack : for i in 0 to N_BATCH_S-1 generate
        packed(i*64+15 downto i*64+0)  <= sign_ext(ADC_DATA4(0)(i));
        packed(i*64+31 downto i*64+16) <= sign_ext(ADC_DATA4(1)(i));
        packed(i*64+47 downto i*64+32) <= sign_ext(ADC_DATA4(2)(i));
        packed(i*64+63 downto i*64+48) <= sign_ext(ADC_DATA4(3)(i));
    end generate;

    BATCH_DATA <= packed;

    -- -------------------------------------------------------------------------
    -- Round-robin FSM (CLK_ADC)
    -- -------------------------------------------------------------------------
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            if RST = '1' then
                batch_cnt  <= 0;
                lane_sel   <= 0;
                we_r       <= (others => '0');
                overflow_r <= '0';
            else
                we_r       <= (others => '0');
                overflow_r <= '0';

                if DATA_STR = '1' then
                    -- Write this batch to the current lane if FIFO has space
                    if LANE_BUSY(lane_sel) = '0' then
                        we_r(lane_sel) <= '1';
                    else
                        overflow_r <= '1';
                    end if;

                    -- Advance counters every batch
                    if batch_cnt = N_BATCHES-1 then
                        batch_cnt <= 0;
                        if lane_sel = N_LANES-1 then
                            lane_sel <= 0;
                        else
                            lane_sel <= lane_sel + 1;
                        end if;
                    else
                        batch_cnt <= batch_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    LANE_WE        <= we_r;
    CHUNK_OVERFLOW <= overflow_r;

end architecture rtl;
