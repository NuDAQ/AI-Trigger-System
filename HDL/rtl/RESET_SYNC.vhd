library ieee;
use ieee.std_logic_1164.all;

entity RESET_SYNC is
    generic (
        STAGES : positive := 2
    );
    port (
        CLK       : in  std_logic;
        RST_ASYNC : in  std_logic;
        RST_SYNC  : out std_logic
    );
end entity RESET_SYNC;

architecture rtl of RESET_SYNC is
    signal sync_ff : std_logic_vector(STAGES - 1 downto 0) := (others => '1');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync_ff : signal is "TRUE";
begin
    process(CLK, RST_ASYNC)
    begin
        if RST_ASYNC = '1' then
            sync_ff <= (others => '1');
        elsif rising_edge(CLK) then
            sync_ff <= sync_ff(STAGES - 2 downto 0) & '0';
        end if;
    end process;

    RST_SYNC <= sync_ff(STAGES - 1);
end architecture rtl;
