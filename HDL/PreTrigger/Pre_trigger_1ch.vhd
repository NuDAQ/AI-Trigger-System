library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;
use work.ila_pkg.all;

Entity PRE_TRIGGER_1CH is
generic (CH : integer := 1);
Port(
	CLK			: IN  std_logic;
	RESET		: IN  std_logic;
	DATA_STR	: IN  std_logic;
	ADC_DATA	: IN  adc_data_type;														-- sample 15 is the newest
	THRESH		: IN  std_logic_vector(11 downto 0);
	WINDOW		: IN  std_logic_vector(7 downto 0);									-- gate length 0..255 ns
	GATE		: OUT std_logic_vector(0 to 15)
	);
end PRE_TRIGGER_1CH;

architecture behav of PRE_TRIGGER_1CH is

    COMPONENT ila_1
    
    PORT (
        clk     : IN STD_LOGIC;
        probe0  : IN STD_LOGIC_VECTOR(191 DOWNTO 0); 
        probe1  : IN STD_LOGIC_VECTOR( 15 DOWNTO 0); 
        probe2  : IN STD_LOGIC_VECTOR( 11 DOWNTO 0); 
        probe3  : IN STD_LOGIC_VECTOR(  7 DOWNTO 0); 
        probe4  : IN STD_LOGIC_VECTOR(  7 DOWNTO 0); 
        probe5  : IN STD_LOGIC_VECTOR(127 DOWNTO 0); 
        probe6  : IN STD_LOGIC_VECTOR( 15 DOWNTO 0);
        probe7  : IN STD_LOGIC_VECTOR(  0 DOWNTO 0);
        probe8  : IN STD_LOGIC_VECTOR(  0 DOWNTO 0)
    );
    END COMPONENT  ;

	signal adc_data_i		: adc_data_type;
	signal time_window		: time_window_type;										-- how many samples were after the last trigger
	signal time_window_d	: unsigned(7 downto 0);									-- how many samples were after the last trigger - spill over 
	signal ot				: std_logic_vector(0 to 15);							-- data over threshold
	constant no_ot			: std_logic_vector(0 to 15) := (others => '0');	-- not over threshold (constant)
	signal samples16        : std_logic_vector(191 downto 0);
	
begin

-- ---------------------------------------------------------------
--				action for data strobe
-- ---------------------------------------------------------------

	process(CLK, RESET)
    variable v_ot          : std_logic_vector(0 to 15);
    variable v_time_window : time_window_type;
    variable v_gate        : std_logic_vector(0 to 15);
	begin
		if RESET = '1' then
        ot            <= (others => '0');
        GATE          <= (others => '0');
        time_window   <= (others => x"00");
        time_window_d <= x"00";
			
		elsif rising_edge(CLK) then
			if DATA_STR = '1' then

            -- Initialize variables for this batch
            v_ot          := (others => '0');
            v_time_window := (others => x"00");
            v_gate        := (others => '0');

            -- -------------------------------------------------------
            --  Sample 0: no earlier within-batch sample, use carry-over
            -- -------------------------------------------------------
            if ADC_DATA(0) > THRESH then
                v_ot(0)          := '1';
                v_time_window(0) := x"01";
                v_gate(0)        := '1';
            elsif time_window_d /= x"00" and time_window_d < unsigned(WINDOW) then
                v_time_window(0) := time_window_d + 1;
                v_gate(0)        := '1';
			end if;

            -- -------------------------------------------------------
            --  Samples 1..15
            -- -------------------------------------------------------
            for i in 1 to 15 loop

                if ADC_DATA(i) > THRESH then
                    -- Current sample is over threshold: open gate, start window
                    v_ot(i)          := '1';
                    v_time_window(i) := x"01";
                    v_gate(i)        := '1';

                else
                    -- Current sample is not over threshold
                    if v_ot(0 to i-1) = no_ot(0 to i-1) then
                        -- No OT in this batch up to sample i-1: use cross-batch carry-over
					if time_window_d /= x"00" then
						if to_unsigned(i, 8) + time_window_d + 1 < unsigned(WINDOW) then
                                v_time_window(i) := to_unsigned(i, 8) + time_window_d + 1;
                                v_gate(i)        := '1';
						end if;
					end if;				
				else
                        -- At least one earlier sample was OT: find most recent (last-wins in loop)
                        for k in 0 to i-1 loop
                            if v_ot(k) = '1' then
							if to_unsigned(i, 8) - to_unsigned(k, 8) + 1 < unsigned(WINDOW) then
                                    v_time_window(i) := to_unsigned(i, 8) - to_unsigned(k, 8) + 1;
                                    v_gate(i)        := '1';
							else
                                    v_time_window(i) := x"00";
                                    v_gate(i)        := '0';
							end if;
						end if;
					end loop;

				end if;
			end if;			

            end loop;

            -- Commit variables to signals; time_window_d carries sample-15
            -- window count into the NEXT batch (read as signal → previous value)
            GATE          <= v_gate;
            ot            <= v_ot;
            time_window   <= v_time_window;
            time_window_d <= v_time_window(15);
        
        else
            GATE          <= (others => '0');
            ot            <= (others => '0');
            time_window   <= (others => x"00");

        end if;
		end if;
	end process;


    -- gen_ila: if (CH < 1 and SET_PRE_TRIGGER_ILA = 1) generate
    -- 
    --     ila_pre_trig_ch : ila_1
    --     PORT MAP (
    --         clk        => clk,
    --         probe0     => ADC_DATA(0) & ADC_DATA(1) & ...
    --         probe1     => GATE, 
    --         probe2     => THRESH, 
    --         probe3     => WINDOW, 
    --         probe4     => std_logic_vector(time_window_d),
    --         probe5     => std_logic_vector(time_window(0)) ...
    --         probe6     => ot,
    --         probe7(0)  => DATA_STR,
    --         probe8(0)  => RESET	
    --     );
    -- 
    -- end generate;

end behav;
			
			
			
			