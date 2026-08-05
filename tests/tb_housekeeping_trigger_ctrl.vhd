library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_housekeeping_trigger_ctrl is
end entity tb_housekeeping_trigger_ctrl;

architecture sim of tb_housekeeping_trigger_ctrl is
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal active_mode          : std_logic_vector(3 downto 0) := TRIGGER_MODE_CAPTURE_ALL;
    signal mode_start           : std_logic := '0';
    signal accept_new_work      : std_logic := '0';
    signal data_str             : std_logic := '0';
    signal write_chunk_id       : chunk_id_t := (others => '0');
    signal write_beat_offset    : beat_offset_t := (others => '0');
    signal write_timestamp      : timestamp_t := (others => '0');
    signal chunk_commit         : std_logic := '0';
    signal commit_chunk_id      : chunk_id_t := (others => '0');
    signal commit_timestamp     : timestamp_t := (others => '0');
    signal force_trigger        : std_logic := '0';
    signal request_valid        : std_logic;
    signal request_ready        : std_logic := '0';
    signal request_value        : event_request_t;
    signal event_finished       : std_logic := '0';
    signal request_failed       : std_logic := '0';
    signal busy                 : std_logic;
    signal event_loss_pulse     : std_logic;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.HOUSEKEEPING_TRIGGER_CTRL
        port map (
            CLK                  => clk,
            RST                  => rst,
            ACTIVE_MODE          => active_mode,
            MODE_START           => mode_start,
            ACCEPT_NEW_WORK      => accept_new_work,
            DATA_STR             => data_str,
            WRITE_CHUNK_ID       => write_chunk_id,
            WRITE_BEAT_OFFSET    => write_beat_offset,
            WRITE_TIMESTAMP      => write_timestamp,
            CHUNK_COMMIT         => chunk_commit,
            COMMIT_CHUNK_ID      => commit_chunk_id,
            COMMIT_TIMESTAMP     => commit_timestamp,
            FORCE_TRIGGER        => force_trigger,
            REQUEST_VALID        => request_valid,
            REQUEST_READY        => request_ready,
            REQUEST_VALUE        => request_value,
            EVENT_FINISHED       => event_finished,
            REQUEST_FAILED       => request_failed,
            BUSY                 => busy,
            EVENT_LOSS_PULSE     => event_loss_pulse
        );

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';

        accept_new_work <= '1';
        mode_start      <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';

        commit_chunk_id  <= to_unsigned(9, CHUNK_ID_WIDTH);
        commit_timestamp <= to_unsigned(55, TIMESTAMP_WIDTH);
        chunk_commit     <= '1';
        wait until rising_edge(clk);
        chunk_commit <= '0';
        wait for 1 ps;
        assert request_valid = '1' and busy = '1'
            report "Capture-All commit must create a pending Event Request" severity failure;
        assert request_value.start_address.chunk_id = to_unsigned(9, CHUNK_ID_WIDTH) and
               request_value.start_address.beat_offset = 0 and
               request_value.event_timestamp = to_unsigned(55, TIMESTAMP_WIDTH) and
               request_value.trigger_offset = 0 and request_value.score = x"00000000"
            report "Capture-All Event Request metadata is wrong" severity failure;

        request_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        request_ready <= '0';
        assert request_valid = '0' and busy = '0'
            report "Capture-All request must retire after handshake" severity failure;

        active_mode     <= TRIGGER_MODE_EXTERNAL;
        force_trigger   <= '1';
        mode_start      <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        for i in 0 to 2 loop
            wait until rising_edge(clk);
            wait for 1 ps;
            assert request_valid = '0'
                report "FORCE_TRIGGER high at mode entry must not replay" severity failure;
        end loop;

        force_trigger <= '0';
        wait until rising_edge(clk);
        force_trigger <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert request_valid = '0' and busy = '1'
            report "an external edge during DATA_STR=0 must wait for a valid beat" severity failure;

        write_chunk_id    <= to_unsigned(5, CHUNK_ID_WIDTH);
        write_beat_offset <= to_unsigned(12, BEAT_OFFSET_WIDTH);
        write_timestamp   <= to_unsigned(100, TIMESTAMP_WIDTH);
        data_str          <= '1';
        wait until rising_edge(clk);
        data_str <= '0';
        wait for 1 ps;
        assert request_valid = '1'
            report "pending external edge did not anchor to the next accepted beat" severity failure;
        assert request_value.start_address.chunk_id = to_unsigned(4, CHUNK_ID_WIDTH) and
               request_value.start_address.beat_offset = to_unsigned(45, BEAT_OFFSET_WIDTH) and
               request_value.event_timestamp = to_unsigned(100, TIMESTAMP_WIDTH) and
               request_value.trigger_offset = to_unsigned(12, BEAT_OFFSET_WIDTH)
            report "external centered Event Request metadata is wrong" severity failure;

        request_ready <= '1';
        wait until rising_edge(clk);
        request_ready <= '0';
        force_trigger <= '0';
        wait until rising_edge(clk);
        force_trigger <= '1';
        data_str      <= '1';
        wait until rising_edge(clk);
        data_str <= '0';
        wait for 1 ps;
        assert event_loss_pulse = '1' and busy = '1'
            report "a second external edge while busy must be dropped and reported" severity failure;

        event_finished <= '1';
        wait until rising_edge(clk);
        event_finished <= '0';
        wait for 1 ps;
        assert busy = '0'
            report "external mode must rearm after the event enters the output path" severity failure;

        report "tb_housekeeping_trigger_ctrl passed";
        stop;
        wait;
    end process;
end architecture sim;
