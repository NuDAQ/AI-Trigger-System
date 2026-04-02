library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;
use work.ila_pkg.all;

Entity PRE_TRIGGER_1CH is
generic (CH : integer := 0);
Port(
    CLK         : IN  std_logic;
    RESET       : IN  std_logic;
    DATA_STR    : IN  std_logic;
    ADC_DATA    : IN  adc_data_type;             -- sample 15 is the newest
    THRESH      : IN  std_logic_vector(11 downto 0);
    HILO_WINDOW : IN  std_logic_vector( 7 downto 0); -- intra-channel bipolar window length
    GATE        : OUT std_logic_vector(0 to 31)
);
end PRE_TRIGGER_1CH;

architecture behav of PRE_TRIGGER_1CH is

    signal ot_hi    : std_logic_vector(0 to 31);  -- Hi over-threshold flags
    signal ot_lo    : std_logic_vector(0 to 31);  -- Lo over-threshold flags
    signal tw_hi    : time_window_type;            -- Hi window counters (within batch)
    signal tw_lo    : time_window_type;            -- Lo window counters (within batch)
    signal tw_hi_d  : unsigned(7 downto 0);        -- Hi window carry-over (cross-batch)
    signal tw_lo_d  : unsigned(7 downto 0);        -- Lo window carry-over (cross-batch)

    constant no_ot  : std_logic_vector(0 to 15) := (others => '0');

begin

    process(CLK, RESET)
        variable v_ot_hi    : std_logic_vector(0 to 31);
        variable v_ot_lo    : std_logic_vector(0 to 31);
        variable v_tw_hi    : time_window_type;
        variable v_tw_lo    : time_window_type;
        variable v_gate_hi  : std_logic_vector(0 to 31);
        variable v_gate_lo  : std_logic_vector(0 to 31);
        variable adc_s      : signed(11 downto 0);
        variable thresh_pos : signed(11 downto 0);
        variable thresh_neg : signed(11 downto 0);
    begin
        if RESET = '1' then
            ot_hi   <= (others => '0');
            ot_lo   <= (others => '0');
            tw_hi   <= (others => x"00");
            tw_lo   <= (others => x"00");
            tw_hi_d <= x"00";
            tw_lo_d <= x"00";
            GATE    <= (others => '0');

        elsif rising_edge(CLK) then
            if DATA_STR = '1' then

                v_ot_hi   := (others => '0');
                v_ot_lo   := (others => '0');
                v_tw_hi   := (others => x"00");
                v_tw_lo   := (others => x"00");
                v_gate_hi := (others => '0');
                v_gate_lo := (others => '0');

                thresh_pos := signed(THRESH);
                thresh_neg := -signed(THRESH);

                -- -------------------------------------------------------
                --  Sample 0: no within-batch predecessor, use carry-over
                -- -------------------------------------------------------
                adc_s := signed(ADC_DATA(0));

                -- Hi gate for sample 0
                if adc_s > thresh_pos then
                    v_ot_hi(0)   := '1';
                    v_tw_hi(0)   := x"01";
                    v_gate_hi(0) := '1';
                elsif tw_hi_d /= x"00" and tw_hi_d < unsigned(HILO_WINDOW) then
                    v_tw_hi(0)   := tw_hi_d + 1;
                    v_gate_hi(0) := '1';
                end if;

                -- Lo gate for sample 0
                if adc_s < thresh_neg then
                    v_ot_lo(0)   := '1';
                    v_tw_lo(0)   := x"01";
                    v_gate_lo(0) := '1';
                elsif tw_lo_d /= x"00" and tw_lo_d < unsigned(HILO_WINDOW) then
                    v_tw_lo(0)   := tw_lo_d + 1;
                    v_gate_lo(0) := '1';
                end if;

                -- -------------------------------------------------------
                --  Samples 1..31
                -- -------------------------------------------------------
                for i in 1 to 31 loop
                    adc_s := signed(ADC_DATA(i));

                    -- Hi gate
                    if adc_s > thresh_pos then
                        v_ot_hi(i)   := '1';
                        v_tw_hi(i)   := x"01";
                        v_gate_hi(i) := '1';
                    else
                        if v_ot_hi(0 to i-1) = no_ot(0 to i-1) then
                            -- No Hi OT in this batch up to i-1: use cross-batch carry-over
                            if tw_hi_d /= x"00" then
                                if to_unsigned(i, 8) + tw_hi_d + 1 < unsigned(HILO_WINDOW) then
                                    v_tw_hi(i)   := to_unsigned(i, 8) + tw_hi_d + 1;
                                    v_gate_hi(i) := '1';
                                end if;
                            end if;
                        else
                            -- At least one Hi OT earlier in batch: find most recent (last-wins)
                            for k in 0 to i-1 loop
                                if v_ot_hi(k) = '1' then
                                    if to_unsigned(i, 8) - to_unsigned(k, 8) + 1 < unsigned(HILO_WINDOW) then
                                        v_tw_hi(i)   := to_unsigned(i, 8) - to_unsigned(k, 8) + 1;
                                        v_gate_hi(i) := '1';
                                    else
                                        v_tw_hi(i)   := x"00";
                                        v_gate_hi(i) := '0';
                                    end if;
                                end if;
                            end loop;
                        end if;
                    end if;

                    -- Lo gate (same structure, mirrored for negative threshold)
                    if adc_s < thresh_neg then
                        v_ot_lo(i)   := '1';
                        v_tw_lo(i)   := x"01";
                        v_gate_lo(i) := '1';
                    else
                        if v_ot_lo(0 to i-1) = no_ot(0 to i-1) then
                            -- No Lo OT in this batch up to i-1: use cross-batch carry-over
                            if tw_lo_d /= x"00" then
                                if to_unsigned(i, 8) + tw_lo_d + 1 < unsigned(HILO_WINDOW) then
                                    v_tw_lo(i)   := to_unsigned(i, 8) + tw_lo_d + 1;
                                    v_gate_lo(i) := '1';
                                end if;
                            end if;
                        else
                            -- At least one Lo OT earlier in batch: find most recent (last-wins)
                            for k in 0 to i-1 loop
                                if v_ot_lo(k) = '1' then
                                    if to_unsigned(i, 8) - to_unsigned(k, 8) + 1 < unsigned(HILO_WINDOW) then
                                        v_tw_lo(i)   := to_unsigned(i, 8) - to_unsigned(k, 8) + 1;
                                        v_gate_lo(i) := '1';
                                    else
                                        v_tw_lo(i)   := x"00";
                                        v_gate_lo(i) := '0';
                                    end if;
                                end if;
                            end loop;
                        end if;
                    end if;

                end loop; -- samples 1..15

                -- Commit variables to signals; sample-31 window count carries
                -- into next batch via tw_hi_d / tw_lo_d
                ot_hi   <= v_ot_hi;
                ot_lo   <= v_ot_lo;
                tw_hi   <= v_tw_hi;
                tw_lo   <= v_tw_lo;
                tw_hi_d <= v_tw_hi(31);
                tw_lo_d <= v_tw_lo(31);

                -- Bipolar gate: fire only where BOTH Hi and Lo gates are open
                GATE <= v_gate_hi and v_gate_lo;

            else
                -- No valid data: clear outputs; tw_*_d retain cross-batch carry-over
                GATE    <= (others => '0');
                ot_hi   <= (others => '0');
                ot_lo   <= (others => '0');
                tw_hi   <= (others => x"00");
                tw_lo   <= (others => x"00");
            end if;
        end if;
    end process;

    -- gen_ila: if (CH < 1 and SET_PRE_TRIGGER_ILA = 1) generate
    --
    --     ila_pre_trig_ch : ila_1
    --     PORT MAP (
    --         clk        => clk,
    --         probe0     => ...,
    --         probe1     => GATE,
    --         probe2     => THRESH,
    --         probe3     => HILO_WINDOW,
    --         probe4     => std_logic_vector(tw_hi_d),
    --         probe5     => std_logic_vector(tw_lo_d),
    --         probe6     => ot_hi,
    --         probe7(0)  => DATA_STR,
    --         probe8(0)  => RESET
    --     );
    --
    -- end generate;

end behav;
