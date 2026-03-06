library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

PACKAGE PRE_TRIGGER_pkg IS
		
	type adc_data_type	   is array (0 to 15) of STD_LOGIC_VECTOR(11 downto 0);
	type adc_data8_type	   is array (0 to  7) of adc_data_type;
	type time_window_type  is array (0 to 15) of unsigned(7 downto 0);
	type gate8_type 	   is array (0 to  7) of STD_LOGIC_VECTOR(0 to 15);
	type mult16_type 	   is array (0 to 15) of STD_LOGIC_VECTOR(0 to 7);	

	
End package PRE_TRIGGER_pkg;

