library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


entity MULT2BIN is
    Port (
        IN_VEC 	: in  STD_LOGIC_VECTOR(7 downto 0);
		BIN_THR	: in  STD_LOGIC_VECTOR(3 downto 0);
		TRIG	: out STD_LOGIC
    );
end MULT2BIN;

architecture Behavioral of MULT2BIN is
	signal count	: unsigned(3 downto 0);
begin
   process(in_vec)
      variable temp_count : integer range 0 to 8 := 0;
		begin
			temp_count := 0;
			-- Count number of '1's in the input vector
			for i in 0 to 7 loop
				if in_vec(i) = '1' then
					 temp_count := temp_count + 1;
				end if;
			end loop;
			-- Convert integer count to 4-bit std_logic_vector
			count <= to_unsigned(temp_count, 4);
	  
	end process;
	
	process(count)	
	begin
		if count >= unsigned(BIN_THR) then
			TRIG	<= '1';
		else
			TRIG	<= '0';
		end if;	 
	end process; 
	 
end Behavioral;