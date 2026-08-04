library ieee;
use ieee.std_logic_1164.all;

entity tb_trigger_mode_ctrl is
end entity tb_trigger_mode_ctrl;

architecture sim of tb_trigger_mode_ctrl is
    constant CLK_PERIOD : time := 4 ns;

    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal requested_mode   : std_logic_vector(3 downto 0) := "0000";
    signal chunk_boundary   : std_logic := '0';
    signal path_idle        : std_logic := '1';
    signal active_mode      : std_logic_vector(3 downto 0);
    signal switch_pending   : std_logic;
    signal invalid_request  : std_logic;
    signal accept_new_work  : std_logic;
    signal mode_start       : std_logic;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.TRIGGER_MODE_CTRL
        port map (
            CLK                => clk,
            RST                => rst,
            REQUESTED_MODE     => requested_mode,
            CHUNK_BOUNDARY     => chunk_boundary,
            PATH_IDLE          => path_idle,
            ACTIVE_MODE        => active_mode,
            MODE_SWITCH_PENDING => switch_pending,
            INVALID_REQUEST    => invalid_request,
            ACCEPT_NEW_WORK    => accept_new_work,
            MODE_START         => mode_start
        );

    stimulus : process
    begin
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = "1111"
            report "reset must hold the active mode fail-closed" severity failure;
        assert switch_pending = '1'
            report "the first requested mode must remain pending during reset" severity failure;
        assert accept_new_work = '0'
            report "reset hold must not accept trigger work" severity failure;

        rst <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = "1111"
            report "a requested mode must not apply before a chunk boundary" severity failure;
        assert mode_start = '0'
            report "mode start must stay low before the safe boundary" severity failure;

        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert active_mode = "0000"
            report "Capture-All must apply at the first safe chunk boundary" severity failure;
        assert switch_pending = '0'
            report "the applied mode must no longer be pending" severity failure;
        assert accept_new_work = '1'
            report "a valid active mode must accept new work" severity failure;
        assert mode_start = '1'
            report "applying the first mode must pulse MODE_START" severity failure;

        wait until rising_edge(clk);
        wait for 1 ps;
        assert mode_start = '0'
            report "MODE_START must be a one-cycle pulse" severity failure;

        requested_mode <= "0010";
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = "0000"
            report "a new request must not change the active mode mid-chunk" severity failure;
        assert switch_pending = '1'
            report "a different requested mode must assert pending" severity failure;
        assert accept_new_work = '1'
            report "the old mode may accept work until the stop boundary" severity failure;

        requested_mode <= "0011";
        path_idle <= '0';
        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert active_mode = "0000"
            report "the old mode must remain active while accepted work drains" severity failure;
        assert accept_new_work = '0'
            report "no new work may enter after the stop boundary" severity failure;

        requested_mode <= "0010";
        path_idle <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert active_mode = "0000"
            report "drain completion alone must not apply a mode mid-chunk" severity failure;

        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert active_mode = "0010"
            report "the latest request must apply at the safe boundary" severity failure;
        assert switch_pending = '0'
            report "the final applied request must clear pending" severity failure;
        assert accept_new_work = '1'
            report "the newly applied valid mode must accept work" severity failure;
        assert mode_start = '1'
            report "a safe mode application must pulse MODE_START" severity failure;

        wait until rising_edge(clk);
        wait for 1 ps;
        requested_mode <= "0011";
        path_idle <= '0';
        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert accept_new_work = '0'
            report "a second transition must stop at its boundary" severity failure;

        requested_mode <= "0010";
        wait for 1 ps;
        assert switch_pending = '0'
            report "returning to the active request must clear pending immediately" severity failure;
        assert accept_new_work = '0'
            report "a cancelled transition must stay stopped until a boundary" severity failure;

        path_idle <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert accept_new_work = '0'
            report "drain completion must not restart a cancelled transition mid-chunk" severity failure;

        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert active_mode = "0010"
            report "a cancelled transition must retain the active mode" severity failure;
        assert accept_new_work = '1'
            report "a cancelled transition must restart at the safe boundary" severity failure;
        assert mode_start = '1'
            report "restart after cancellation must pulse MODE_START" severity failure;

        requested_mode <= "0101";
        wait for 1 ps;
        assert invalid_request = '1'
            report "a reserved request must assert INVALID_REQUEST" severity failure;

        chunk_boundary <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        chunk_boundary <= '0';
        assert active_mode = "0101"
            report "a reserved request must still apply at a safe boundary" severity failure;
        assert switch_pending = '0'
            report "an applied reserved request must no longer be pending" severity failure;
        assert accept_new_work = '0'
            report "a reserved active mode must fail closed" severity failure;

        report "tb_trigger_mode_ctrl passed";
        std.env.stop;
        wait;
    end process;
end architecture sim;
