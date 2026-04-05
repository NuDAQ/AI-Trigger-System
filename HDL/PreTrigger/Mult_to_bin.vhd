library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- MULT2BIN: Combinational multiplicity threshold
-- Counts the number of '1' bits in IN_VEC (one bit per channel, 4 channels).
-- Asserts TRIG when the count is >= BIN_THR.

entity MULT2BIN is
    Port (
        IN_VEC  : in  STD_LOGIC_VECTOR(3 downto 0);  -- one bit per channel (4 channels)
        BIN_THR : in  STD_LOGIC_VECTOR(3 downto 0);
        TRIG    : out STD_LOGIC
    );
end MULT2BIN;

architecture Behavioral of MULT2BIN is
    signal count : unsigned(3 downto 0);
begin

    process(IN_VEC)
        variable temp_count : integer range 0 to 4 := 0;
    begin
        temp_count := 0;
        for i in 0 to 3 loop
            if IN_VEC(i) = '1' then
                temp_count := temp_count + 1;
            end if;
        end loop;
        count <= to_unsigned(temp_count, 4);
    end process;

    process(count)
    begin
        if count >= unsigned(BIN_THR) then
            TRIG <= '1';
        else
            TRIG <= '0';
        end if;
    end process;

end Behavioral;
