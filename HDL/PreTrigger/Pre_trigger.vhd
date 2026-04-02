library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

-- PRE_TRIGGER : 4-channel Hi-Lo bipolar pre-trigger top level
--
-- Three-stage pipeline (total latency: 2 clock cycles from DATA_STR to PRE_TRIG):
--
--   Stage 1 – PRE_TRIGGER_1CH x4  [registered, 1 cycle]
--     Per-channel bipolar gate.  GATE(i)='1' only when both a positive and a
--     negative threshold crossing occurred within HILO_WINDOW samples (intra-
--     channel window, the longer window).
--
--   Stage 2 – coinc_proc           [registered, 1 cycle, reads gate4 via data_str_d]
--     Inter-channel coincidence-window smear.  For each channel the bipolar gate
--     is extended by COINC_WINDOW samples (the shorter window) so that bipolar
--     events on different channels that are slightly offset in time are still
--     counted as coincident.
--
--     Algorithm: same sliding-window OR structure as PRE_TRIGGER_1CH.
--       coinc4(c)(i) = 1  if  gate4(c)(k)=1 for any k in [i-W+1, i]  (within batch)
--                          OR  i < coinc_d(c)                          (cross-batch)
--     All 32 x 4 output bits are computed in parallel with NO sequential
--     dependency between samples.  Carry is updated once per batch.
--
--   Stage 3 – MULT2BIN x32  [combinational]
--     At each of the 32 time bins, count channels with coincidence gate open.
--     Assert PRE_TRIG if the count reaches BIN_THR at any time bin.
--
-- *** Constraint ***
--   HILO_WINDOW and COINC_WINDOW must each be <= 32 (batch size) for correct
--   single-batch carry behaviour.

entity PRE_TRIGGER is
port (
    CLK          : in  std_logic;
    RESET        : in  std_logic;
    DATA_STR     : in  std_logic;
    ADC_DATA4    : in  adc_data4_type;
    THRESH       : in  std_logic_vector(11 downto 0);
    HILO_WINDOW  : in  std_logic_vector( 7 downto 0); -- intra-channel bipolar window (longer)
    COINC_WINDOW : in  std_logic_vector( 7 downto 0); -- inter-channel coincidence window (shorter)
    BIN_THR      : in  std_logic_vector( 3 downto 0);
    PRE_TRIG     : out std_logic
);
end PRE_TRIGGER;

architecture behav of PRE_TRIGGER is

    signal gate4      : gate4_type;        -- bipolar gate outputs, registered in 1CH
    signal coinc4     : gate4_type;        -- gates after coincidence-window smear
    signal mult16     : mult4x16_type;     -- 4-ch multiplicity vector per time bin
    signal trig32     : std_logic_vector(31 downto 0); -- per-bin trigger (combinational)
    signal coinc_d    : carry4_type;       -- inter-channel coincidence carry-over
    signal data_str_d : std_logic;         -- DATA_STR delayed 1 cycle (aligns with gate4)

begin

    -- ------------------------------------------------------------------
    --  Stage 1: 4 per-channel Hi-Lo bipolar pre-triggers
    -- ------------------------------------------------------------------
    chan_gen: for i in 0 to 3 generate
        U_CH: entity work.PRE_TRIGGER_1CH
        generic map (CH => i)
        port map (
            CLK         => CLK,
            RESET       => RESET,
            DATA_STR    => DATA_STR,
            ADC_DATA    => ADC_DATA4(i),
            THRESH      => THRESH,
            HILO_WINDOW => HILO_WINDOW,
            GATE        => gate4(i)
        );
    end generate;

    -- ------------------------------------------------------------------
    --  Pipeline register: gate4 is registered inside PRE_TRIGGER_1CH,
    --  so it is valid one cycle after DATA_STR.  data_str_d tracks this.
    -- ------------------------------------------------------------------
    str_pipe: process(CLK, RESET)
    begin
        if RESET = '1' then
            data_str_d <= '0';
        elsif rising_edge(CLK) then
            data_str_d <= DATA_STR;
        end if;
    end process;

    -- ------------------------------------------------------------------
    --  Stage 2: inter-channel coincidence-window smear
    --
    --  Same sliding-window OR algorithm as PRE_TRIGGER_1CH Step 2/3,
    --  applied per channel to the gate4 inputs.
    --
    --  coinc4(c)(i) = 1  if  gate4(c)(k)=1 for k in [i-W+1, i]  (within batch)
    --                     OR  i < coinc_d(c)                      (cross-batch carry)
    --
    --  After loop unrolling every (c, i, k) triple is an independent path.
    --  No sequential dependency between samples or channels.
    -- ------------------------------------------------------------------
    coinc_proc: process(CLK, RESET)
        variable v_coinc     : gate4_type;
        variable coinc_next  : carry4_type;
        variable coinc_int   : integer range 0 to 255;
        variable carry_int   : integer range 0 to 255;
    begin
        if RESET = '1' then
            coinc4  <= (others => (others => '0'));
            coinc_d <= (others => (others => '0'));

        elsif rising_edge(CLK) then
            if data_str_d = '1' then

                v_coinc    := (others => (others => '0'));
                coinc_next := (others => (others => '0'));
                coinc_int  := to_integer(unsigned(COINC_WINDOW));

                for c in 0 to 3 loop
                    carry_int := to_integer(coinc_d(c)); -- value from previous batch

                    -- Sliding-window gate: all 32 samples computed in parallel
                    for i in 0 to 31 loop
                        -- (a) Cross-batch carry
                        if i < carry_int then
                            v_coinc(c)(i) := '1';
                        end if;
                        -- (b) Within-batch sliding-window OR
                        for k in 0 to 31 loop
                            if k <= i and (i - k) < coinc_int then
                                if gate4(c)(k) = '1' then
                                    v_coinc(c)(i) := '1';
                                end if;
                            end if;
                        end loop;
                    end loop;

                    -- Carry update: last crossing (largest k) wins;
                    -- carry = max(0,  k + COINC_WINDOW - 32)
                    for k in 0 to 31 loop
                        if gate4(c)(k) = '1' and (k + coinc_int) > 32 then
                            coinc_next(c) := to_unsigned(k + coinc_int - 32, 8);
                        end if;
                    end loop;
                end loop;

                coinc4  <= v_coinc;
                coinc_d <= coinc_next;

            else
                coinc4 <= (others => (others => '0'));
                -- coinc_d retains state: coincidence window persists across gaps
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------
    --  Stage 3: multiplicity check across 4 channels per time bin
    -- ------------------------------------------------------------------
    mult_gen: for i in 0 to 31 generate
        mult16(i) <= coinc4(0)(i) & coinc4(1)(i) & coinc4(2)(i) & coinc4(3)(i);

        U_MULT: entity work.MULT2BIN
        port map (
            IN_VEC  => mult16(i),
            BIN_THR => BIN_THR,
            TRIG    => trig32(i)
        );
    end generate;

    PRE_TRIG <= '0' when trig32 = x"00000000" else '1';

end behav;
