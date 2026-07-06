library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_reset_sync is
end entity tb_reset_sync;

architecture sim of tb_reset_sync is
    signal clk       : std_logic := '0';
    signal rst_async : std_logic := '1';
    signal rst_sync  : std_logic;
begin
    clk <= not clk after 5 ns;

    u_dut : entity work.RESET_SYNC
        port map (
            CLK       => clk,
            RST_ASYNC => rst_async,
            RST_SYNC  => rst_sync
        );

    process
    begin
        wait for 1 ns;
        assert rst_sync = '1'
            report "reset synchronizer must assert from its initialized state"
            severity failure;

        rst_async <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rst_sync = '1'
            report "reset synchronizer released too early after one clock"
            severity failure;

        wait until rising_edge(clk);
        wait for 1 ns;
        assert rst_sync = '0'
            report "reset synchronizer did not release after two clocks"
            severity failure;

        rst_async <= '1';
        wait for 1 ns;
        assert rst_sync = '1'
            report "reset synchronizer did not assert asynchronously"
            severity failure;

        report "tb_reset_sync passed";
        stop;
    end process;
end architecture sim;
