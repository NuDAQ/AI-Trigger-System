-- =============================================================================
-- ADC_CHUNK_DISTRIBUTOR
-- CLK_ADC domain.
--
-- Accumulates incoming ADC batches (16 samples/batch, 4 channels) and
-- distributes complete 256-sample chunks to 6 CNN lanes in round-robin order.
--
-- On every DATA_STR pulse one batch arrives.  After 16 batches the chunk is
-- complete: LANE_WE is pulsed for the current lane, BATCH_ADDR and BATCH_DATA
-- carry the packed write payload, then the lane index advances.
--
-- If the next lane is still busy (LANE_BUSY high), CHUNK_OVERFLOW is asserted
-- and the chunk is dropped (not written).
--
-- BATCH_DATA packing (one 64-bit word per time-step, 16 words per batch):
--   word[i] bits [15: 0] = ch0, sample i, sign-extended 12->16 bit
--   word[i] bits [31:16] = ch1, sample i, sign-extended 12->16 bit
--   word[i] bits [47:32] = ch2, sample i, sign-extended 12->16 bit
--   word[i] bits [63:48] = ch3, sample i, sign-extended 12->16 bit
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity ADC_CHUNK_DISTRIBUTOR is
    port (
        CLK_ADC        : in  std_logic;
        RST            : in  std_logic;   -- active-high, synchronous

        -- ADC input (CLK_ADC domain)
        DATA_STR       : in  std_logic;   -- one pulse per 16-sample batch
        ADC_DATA4      : in  adc_data4_t;

        -- Feedback from lanes (CLK_ADC domain)
        LANE_BUSY      : in  lane_busy_t;

        -- To CNN_CORE_LANE array (CLK_ADC domain)
        LANE_WE        : out std_logic_vector(N_LANES-1 downto 0);
        BATCH_ADDR     : out std_logic_vector(3 downto 0);   -- 0-15
        BATCH_DATA     : out std_logic_vector(N_BATCH_S*64-1 downto 0);  -- 1024-bit

        -- Status (CLK_ADC domain)
        CHUNK_OVERFLOW : out std_logic    -- sticky: chunk dropped, lane was busy
    );
end entity ADC_CHUNK_DISTRIBUTOR;

architecture rtl of ADC_CHUNK_DISTRIBUTOR is

    signal batch_cnt  : integer range 0 to N_BATCHES-1 := 0;
    signal lane_sel   : integer range 0 to N_LANES-1   := 0;
    signal overflow_r : std_logic := '0';

    -- Combinational packed data: sign-extend each 12-bit ADC sample to 16 bits
    signal packed : std_logic_vector(N_BATCH_S*64-1 downto 0);

    function sign_ext(s : std_logic_vector(11 downto 0)) return std_logic_vector is
    begin
        return s(11) & s(11) & s(11) & s(11) & s;
    end function;

begin

    -- -------------------------------------------------------------------------
    -- Combinational packing: ADC_DATA4 -> 1024-bit BATCH_DATA
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
                LANE_WE    <= (others => '0');
                BATCH_ADDR <= (others => '0');
                overflow_r <= '0';
            else
                LANE_WE    <= (others => '0');  -- default: no write
                overflow_r <= '0';

                if DATA_STR = '1' then
                    BATCH_ADDR <= std_logic_vector(to_unsigned(batch_cnt, 4));

                    if LANE_BUSY(lane_sel) = '1' then
                        -- Lane not yet drained; drop chunk
                        overflow_r <= '1';
                    else
                        -- Write this batch to the selected lane
                        LANE_WE(lane_sel) <= '1';
                    end if;

                    -- Advance counters regardless of overflow
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

    CHUNK_OVERFLOW <= overflow_r;

end architecture rtl;
