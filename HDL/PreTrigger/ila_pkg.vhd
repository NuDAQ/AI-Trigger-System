library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

PACKAGE ila_pkg IS
		
	constant SET_ILA_ALL           : integer := 1;
		
	constant SET_PRE_TRIGGER_ILA   : integer := 0;
	constant SET_REC_MEM_ILA       : integer := 0;
    constant SET_UART_ILA          : integer := 0;
	
End package ila_pkg;