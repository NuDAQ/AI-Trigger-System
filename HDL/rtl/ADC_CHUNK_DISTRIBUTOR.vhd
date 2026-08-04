-- =============================================================================
-- ADC_CHUNK_DISTRIBUTOR
-- CLK_ADC domain.
--
-- DATA_STR is asserted every CLK_ADC cycle (continuous 1 Gsps ADC stream).
-- Each cycle carries one 4-sample beat across 8 raw ADC channels.  Only the
-- leading four channels are packed into the CNN trigger stream.
-- After N_BATCHES (64) cycles the complete 256-sample chunk is committed to the
-- selected lane via LANE_WE.  The lane counter advances round-robin every chunk.
--
-- CHUNK_BUSY feedback (CLK_ADC domain) means the selected lane cannot accept
-- a complete 16-batch chunk.  The decision is made once at the chunk boundary:
-- either all 64 beats are written, or the whole chunk is dropped.
--
-- BATCH_DATA packing (256-bit = 2 words x 128-bit):
--   XPM width-conversion FIFO readout emits the low 128-bit segment of a
--   256-bit write first.  Keep chronological CNN beats in ascending 128-bit
--   segment order so the read side sees samples 0-1, then samples 2-3.
--
--   beat[p] low  64 bits = row 2*p:
--     bits [15: 0] = ch0, quantized 12-bit ADC -> ap_fixed<9,4>
--     bits [31:16] = ch1
--     bits [47:32] = ch2
--     bits [63:48] = ch3
--   beat[p] high 64 bits = row 2*p+1 with the same channel layout.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity ADC_CHUNK_DISTRIBUTOR is
    port (
        CLK_ADC        : in  std_logic;
        RST            : in  std_logic;

        DATA_STR       : in  std_logic;   -- beat-valid, normally continuous
        ADC_DATA4      : in  adc_data4_t;
        ENABLE         : in  std_logic;

        LANE_BUSY      : in  lane_busy_t; -- FIFO full per lane (CLK_ADC domain)

        LANE_WE        : out std_logic_vector(N_LANES-1 downto 0);
        BATCH_DATA     : out std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
        CHUNK_ID       : out chunk_id_t;
        CHUNK_TIMESTAMP : out timestamp_t;

        CHUNK_OVERFLOW : out std_logic
    );
end entity ADC_CHUNK_DISTRIBUTOR;

architecture rtl of ADC_CHUNK_DISTRIBUTOR is

    signal batch_cnt  : integer range 0 to N_BATCHES-1 := 0;
    signal lane_sel   : integer range 0 to N_LANES-1   := 0;
    signal chunk_id_r : chunk_id_t := (others => '0');
    signal chunk_timestamp_r : timestamp_t := (others => '0');
    signal drop_chunk : std_logic := '0';
    signal overflow_comb : std_logic := '0';
    signal we_comb       : std_logic_vector(N_LANES-1 downto 0) := (others => '0');

    -- synthesis translate_off
    constant DEBUG_EVENTS : integer := 160;
    signal dbg_events : integer := 0;
    signal dbg_chunk_seq : integer := 0;
    -- synthesis translate_on

begin

    -- -------------------------------------------------------------------------
    -- Combinational packing: 4 ch x 4 samples -> 256-bit FIFO write.
    -- Each 128-bit segment contains two consecutive timesteps.  Segments are
    -- written in chronological order because the asymmetric FIFO read side
    -- returns the low segment before the high segment.
    -- -------------------------------------------------------------------------
    BATCH_DATA <= pack_cnn_batch(ADC_DATA4);

    process(DATA_STR, ENABLE, batch_cnt, LANE_BUSY, lane_sel, drop_chunk)
        variable selected_lane_accept : boolean;
    begin
        we_comb <= (others => '0');
        overflow_comb <= '0';
        selected_lane_accept :=
            ENABLE = '1' and (
                (batch_cnt = 0 and LANE_BUSY(lane_sel) = '0') or
                (batch_cnt /= 0 and drop_chunk = '0')
            );

        if DATA_STR = '1' then
            if selected_lane_accept then
                we_comb(lane_sel) <= '1';
            elsif ENABLE = '1' then
                overflow_comb <= '1';
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- Round-robin FSM (CLK_ADC)
    -- -------------------------------------------------------------------------
    process(CLK_ADC)
    begin
        if rising_edge(CLK_ADC) then
            if RST = '1' then
                batch_cnt  <= 0;
                lane_sel   <= 0;
                chunk_id_r <= (others => '0');
                chunk_timestamp_r <= (others => '0');
                drop_chunk <= '0';
            else
                if DATA_STR = '1' then
                    -- Decide once at the first batch of a chunk.  This avoids
                    -- partially writing a chunk if a lane becomes unavailable.
                    if batch_cnt = 0 then
                        if ENABLE = '1' then
                            drop_chunk <= LANE_BUSY(lane_sel);
                        else
                            drop_chunk <= '1';
                        end if;
                        -- synthesis translate_off
                        if dbg_events < DEBUG_EVENTS then
                            report "DIST chunk_start seq=" &
                                   integer'image(dbg_chunk_seq) &
                                   " lane=" & integer'image(lane_sel) &
                                   " busy=" & std_logic'image(LANE_BUSY(lane_sel));
                            dbg_events <= dbg_events + 1;
                        end if;
                        -- synthesis translate_on
                    end if;

                    if ENABLE = '1' and not (
                            (batch_cnt = 0 and LANE_BUSY(lane_sel) = '0') or
                            (batch_cnt /= 0 and drop_chunk = '0')) then
                        -- synthesis translate_off
                        if dbg_events < DEBUG_EVENTS then
                            report "DIST drop_batch seq=" &
                                   integer'image(dbg_chunk_seq) &
                                   " lane=" & integer'image(lane_sel) &
                                   " batch=" & integer'image(batch_cnt) &
                                   " busy_now=" & std_logic'image(LANE_BUSY(lane_sel)) &
                                   " drop_chunk=" & std_logic'image(drop_chunk);
                            dbg_events <= dbg_events + 1;
                        end if;
                        -- synthesis translate_on
                    end if;

                    -- Advance counters every batch
                    if batch_cnt = N_BATCHES-1 then
                        batch_cnt <= 0;
                        if lane_sel = N_LANES-1 then
                            lane_sel <= 0;
                        else
                            lane_sel <= lane_sel + 1;
                        end if;
                        chunk_id_r <= chunk_id_r + 1;
                        chunk_timestamp_r <= chunk_timestamp_r + 1;
                        drop_chunk <= '0';
                        -- synthesis translate_off
                        dbg_chunk_seq <= dbg_chunk_seq + 1;
                        -- synthesis translate_on
                    else
                        batch_cnt <= batch_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    LANE_WE        <= we_comb;
    CHUNK_ID       <= chunk_id_r;
    CHUNK_TIMESTAMP <= chunk_timestamp_r;
    CHUNK_OVERFLOW <= overflow_comb;

end architecture rtl;
