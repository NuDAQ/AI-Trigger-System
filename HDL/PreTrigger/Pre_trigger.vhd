library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

Entity PRE_TRIGGER is
Port(
	CLK			: IN  std_logic;
	RESET		: IN  std_logic;
	DATA_STR	: IN  std_logic;
	
	ADC_DATA8	: IN  adc_data8_type;
	
	THRESH		: IN  std_logic_vector(11 downto 0);
	WINDOW		: IN  std_logic_vector( 7 downto 0);									-- gate length 0..255 ns
	BIN_THR		: IN  std_logic_vector( 3 downto 0);
	PRE_TRIG	: OUT std_logic
	);
end PRE_TRIGGER;

architecture behav of PRE_TRIGGER is

	signal gate8 		: gate8_type;	
	signal mult16		: mult16_type;
	signal trig16		: STD_LOGIC_VECTOR(15 downto 0);

	
	begin

	chan_gen: for i in 0 to 7 generate

		U1: entity work.PRE_TRIGGER_1CH
		generic map(CH => i)
		Port map(
			CLK		    => CLK,
			RESET		=> RESET,
			DATA_STR	=> DATA_STR,
			ADC_DATA	=> adc_data8(i),													
			THRESH		=> THRESH,
			WINDOW		=> WINDOW,									-- gate length 0..255 ns
			GATE		=> gate8(i)
			);
	end generate;

	mult_vect_gen:for i in 0 to 15 generate

		mult16(i) <= gate8(0)(i) & gate8(1)(i) & gate8(2)(i) & gate8(3)(i) & gate8(4)(i) & gate8(5)(i) & gate8(6)(i) & gate8(7)(i); 

		U9: entity work.MULT2BIN
		Port map(
			IN_VEC 		=> mult16(i),
			BIN_THR		=> BIN_THR,
			TRIG		=> trig16(i)
		);
	end generate;

	PRE_TRIG <= '0' when trig16 = x"0000" else '1'; 
	
end behav;
			
			
			
			