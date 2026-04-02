library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

Entity PRE_TRIGGER is
Port(
    CLK          : IN  std_logic;
    RESET        : IN  std_logic;
    DATA_STR     : IN  std_logic;
    ADC_DATA4    : IN  adc_data4_type;
    THRESH       : IN  std_logic_vector(11 downto 0);
    HILO_WINDOW  : IN  std_logic_vector( 7 downto 0); -- intra-channel bipolar window (longer)
    COINC_WINDOW : IN  std_logic_vector( 7 downto 0); -- inter-channel coincidence window (shorter)
    BIN_THR      : IN  std_logic_vector( 3 downto 0);
    PRE_TRIG     : OUT std_logic
);
end PRE_TRIGGER;

architecture behav of PRE_TRIGGER is

    signal gate4      : gate4_type;        -- bipolar gate outputs from 4 channels (registered)
    signal coinc4     : gate4_type;        -- gates after coincidence-window smear (registered)
    signal mult16     : mult4x16_type;     -- 4-ch multiplicity vector per time bin
    signal trig32     : STD_LOGIC_VECTOR(31 downto 0); -- per-bin trigger (combinational)
    signal coinc_d    : carry4_type;       -- coincidence window carry-over, one per channel
    signal data_str_d : std_logic;         -- DATA_STR delayed one cycle (aligns with gate4)

begin

    -- ------------------------------------------------------------------
    --  Stage 1: 4 per-channel Hi-Lo bipolar pre-triggers
    -- ------------------------------------------------------------------
    chan_gen: for i in 0 to 3 generate
        U_CH: entity work.PRE_TRIGGER_1CH
        generic map(CH => i)
        Port map(
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
    --  so it is valid one cycle after DATA_STR. data_str_d tracks this.
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
    --  For each channel c and each sample i, coinc4(c)(i) is '1' if
    --  gate4(c)(i) fired OR if gate4(c) fired within the last COINC_WINDOW
    --  samples. A per-channel countdown counter (coinc_d) carries the
    --  window state across batch boundaries.
    --
    --  Note: COINC_WINDOW must be >= 1. If COINC_WINDOW = 0 behaviour
    --  is undefined (counter underflows).
    -- ------------------------------------------------------------------
    coinc_proc: process(CLK, RESET)
        variable v_rem   : carry4_type;
        variable v_coinc : gate4_type;
    begin
        if RESET = '1' then
            coinc4  <= (others => (others => '0'));
            coinc_d <= (others => (others => '0'));

        elsif rising_edge(CLK) then
            if data_str_d = '1' then
                v_rem   := coinc_d;
                v_coinc := (others => (others => '0'));

                for c in 0 to 3 loop
                    for i in 0 to 31 loop
                        if gate4(c)(i) = '1' then
                            -- New bipolar event: open coincidence gate, reset counter
                            v_coinc(c)(i) := '1';
                            v_rem(c)      := unsigned(COINC_WINDOW) - 1;
                        elsif v_rem(c) > 0 then
                            -- No new event, but coincidence window still counting down
                            v_coinc(c)(i) := '1';
                            v_rem(c)      := v_rem(c) - 1;
                        end if;
                    end loop;
                end loop;

                coinc4  <= v_coinc;
                coinc_d <= v_rem;  -- carry into next batch

            else
                coinc4 <= (others => (others => '0'));
                -- coinc_d retains state: window persists across DATA_STR gaps
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------
    --  Stage 3: multiplicity check across 4 channels per time bin
    -- ------------------------------------------------------------------
    mult_gen: for i in 0 to 31 generate
        mult16(i) <= coinc4(0)(i) & coinc4(1)(i) & coinc4(2)(i) & coinc4(3)(i);

        U_MULT: entity work.MULT2BIN
        Port map(
            IN_VEC  => mult16(i),
            BIN_THR => BIN_THR,
            TRIG    => trig32(i)
        );
    end generate;

    PRE_TRIG <= '0' when trig32 = x"00000000" else '1';

end behav;
