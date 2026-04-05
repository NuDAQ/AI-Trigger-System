library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;


entity PRE_TRIGGER is
port (
    CLK          : in  std_logic;
    RESET        : in  std_logic;
    DATA_STR     : in  std_logic;
    ADC_DATA4    : in  adc_data4_type;
    THRESH       : in  std_logic_vector(11 downto 0);
    HILO_WINDOW  : in  std_logic_vector( 4 downto 0); -- Configurable 0 to 16
    COINC_WINDOW : in  std_logic_vector( 5 downto 0); -- Configurable 0 to 32
    BIN_THR      : in  std_logic_vector( 3 downto 0);
    PRE_TRIG     : out std_logic
);
end PRE_TRIGGER;

architecture behav of PRE_TRIGGER is

    signal gate4      : gate4_type;        -- bipolar gate outputs, registered in 1CH
    signal coinc4     : gate4_type;        -- gates after coincidence-window smear
    signal mult32     : mult4x32_type;     -- 4-ch multiplicity vector per time bin
    signal trig32     : std_logic_vector(31 downto 0); -- per-bin trigger (combinational)
    signal coinc_d    : carry4_type;       -- inter-channel coincidence carry-over
    signal data_str_d : std_logic;         -- DATA_STR delayed 1 cycle (aligns with gate4)

begin

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

    str_pipe: process(CLK, RESET)
    begin
        if RESET = '1' then
            data_str_d <= '0';
        elsif rising_edge(CLK) then
            data_str_d <= DATA_STR;
        end if;
    end process;

    coinc_proc: process(CLK, RESET)
        variable v_coinc     : gate4_type;
        variable coinc_next  : carry4_type;
        variable coinc_int   : integer range 0 to 255;
        variable carry_int   : integer range 0 to 255;
        variable last_k      : integer range 0 to 31;
        variable found_k     : std_logic;
    begin
        if RESET = '1' then
            coinc4  <= (others => (others => '0'));
            coinc_d <= (others => (others => '0'));

        elsif rising_edge(CLK) then
            if data_str_d = '1' then

                v_coinc    := (others => (others => '0'));
                coinc_next := (others => (others => '0'));

                if unsigned(COINC_WINDOW) > 32 then
                    coinc_int := 32;
                else
                    coinc_int := to_integer(unsigned(COINC_WINDOW));
                end if;

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

                    last_k  := 0;
                    found_k := '0';
                    for k in 0 to 31 loop
                        if gate4(c)(k) = '1' then last_k := k; found_k := '1'; end if;
                    end loop;

                    coinc_next(c) := (others => '0');
                    if found_k = '1' and (last_k + coinc_int) > 32 then
                        coinc_next(c) := to_unsigned(last_k + coinc_int - 32, 8);
                    end if;
                end loop;

                coinc4  <= v_coinc;
                coinc_d <= coinc_next;

            else
                coinc4 <= (others => (others => '0'));
            end if;
        end if;
    end process;

    mult_gen: for i in 0 to 31 generate
        mult32(i) <= coinc4(0)(i) & coinc4(1)(i) & coinc4(2)(i) & coinc4(3)(i);

        U_MULT: entity work.MULT2BIN
        port map (
            IN_VEC  => mult32(i),
            BIN_THR => BIN_THR,
            TRIG    => trig32(i)
        );
    end generate;

    PRE_TRIG <= '0' when trig32 = x"00000000" else '1';

end behav;
