library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

entity PRE_TRIGGER_1CH is
generic (CH : integer := 0);
port (
    CLK         : in  std_logic;
    RESET       : in  std_logic;
    DATA_STR    : in  std_logic;
    ADC_DATA    : in  adc_data_type;              -- sample 31 is the newest
    THRESH      : in  std_logic_vector(11 downto 0);
    HILO_WINDOW : in  std_logic_vector( 4 downto 0);
    GATE        : out std_logic_vector(0 to 31)
);
end PRE_TRIGGER_1CH;

architecture behav of PRE_TRIGGER_1CH is

    signal carry_count_hi_d : unsigned(7 downto 0);
    signal carry_count_lo_d : unsigned(7 downto 0);

begin

    process(CLK, RESET)
        variable v_ot_hi       : std_logic_vector(0 to 31);
        variable v_ot_lo       : std_logic_vector(0 to 31);
        variable v_gate_hi     : std_logic_vector(0 to 31);
        variable v_gate_lo     : std_logic_vector(0 to 31);
        variable carry_hi_next : unsigned(7 downto 0);
        variable carry_lo_next : unsigned(7 downto 0);
        variable adc_s         : signed(11 downto 0);
        variable thresh_pos    : signed(11 downto 0);
        variable thresh_neg    : signed(11 downto 0);
        variable win_int       : integer range 0 to 255;
        variable carry_hi_int  : integer range 0 to 255;
        variable carry_lo_int  : integer range 0 to 255;
        variable last_hi_k     : integer range 0 to 31;
        variable last_lo_k     : integer range 0 to 31;
        variable found_hi      : std_logic;
        variable found_lo      : std_logic;
    begin
        if RESET = '1' then
            carry_count_hi_d <= (others => '0');
            carry_count_lo_d <= (others => '0');
            GATE             <= (others => '0');

        elsif rising_edge(CLK) then
            if DATA_STR = '1' then

                thresh_pos   := signed(THRESH);
                thresh_neg   := -signed(THRESH);
                
                -- Hardware clamp: Force max value of 16
                if unsigned(HILO_WINDOW) > 16 then
                    win_int := 16;
                else
                    win_int := to_integer(unsigned(HILO_WINDOW));
                end if;
                
                carry_hi_int := to_integer(carry_count_hi_d); -- value from prev batch
                carry_lo_int := to_integer(carry_count_lo_d);

                for i in 0 to 31 loop
                    adc_s := signed(ADC_DATA(i));
                    if adc_s > thresh_pos then
                        v_ot_hi(i) := '1';
                    else
                        v_ot_hi(i) := '0';
                    end if;
                    if adc_s < thresh_neg then
                        v_ot_lo(i) := '1';
                    else
                        v_ot_lo(i) := '0';
                    end if;
                end loop;

                v_gate_hi := (others => '0');
                v_gate_lo := (others => '0');

                for i in 0 to 31 loop
                    -- (a) Cross-batch carry from the previous batch
                    if i < carry_hi_int then v_gate_hi(i) := '1'; end if;
                    if i < carry_lo_int then v_gate_lo(i) := '1'; end if;

                    -- (b) Within-batch sliding-window OR
                    for k in 0 to 31 loop
                        if k <= i and (i - k) < win_int then
                            if v_ot_hi(k) = '1' then v_gate_hi(i) := '1'; end if;
                            if v_ot_lo(k) = '1' then v_gate_lo(i) := '1'; end if;
                        end if;
                    end loop;
                end loop;

                last_hi_k := 0;  last_lo_k := 0;
                found_hi  := '0'; found_lo := '0';

                for k in 0 to 31 loop
                    if v_ot_hi(k) = '1' then last_hi_k := k; found_hi := '1'; end if;
                    if v_ot_lo(k) = '1' then last_lo_k := k; found_lo := '1'; end if;
                end loop;

                carry_hi_next := (others => '0');
                if found_hi = '1' and (last_hi_k + win_int) > 32 then
                    carry_hi_next := to_unsigned(last_hi_k + win_int - 32, 8);
                end if;

                carry_lo_next := (others => '0');
                if found_lo = '1' and (last_lo_k + win_int) > 32 then
                    carry_lo_next := to_unsigned(last_lo_k + win_int - 32, 8);
                end if;

                carry_count_hi_d <= carry_hi_next;
                carry_count_lo_d <= carry_lo_next;

                GATE <= v_gate_hi and v_gate_lo;

            else
                GATE <= (others => '0');
            end if;
        end if;
    end process;

    -- gen_ila: if (CH = 0 and SET_PRE_TRIGGER_ILA = 1) generate
    --     ila_pre_trig_ch : ila_1
    --     PORT MAP (
    --         clk        => CLK,
    --         probe0     => THRESH,
    --         probe1     => HILO_WINDOW,
    --         probe2(0)  => DATA_STR,
    --         probe3(0)  => RESET
    --     );
    -- end generate;

end behav;
