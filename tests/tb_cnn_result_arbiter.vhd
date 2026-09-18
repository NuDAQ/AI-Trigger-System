library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_cnn_result_arbiter is
end entity tb_cnn_result_arbiter;

architecture sim of tb_cnn_result_arbiter is
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal lane_valid           : std_logic_vector(N_LANES - 1 downto 0) := (others => '0');
    signal lane_ready           : std_logic_vector(N_LANES - 1 downto 0);
    signal lane_score           : score_arr_t := (others => (others => '0'));
    signal lane_thresh          : score_arr_t := (others => (others => '0'));
    signal lane_start_chunk     : chunk_id_arr_t := (others => (others => '0'));
    signal lane_start_offset    : beat_offset_arr_t := (others => (others => '0'));
    signal lane_timestamp       : timestamp_arr_t := (others => (others => '0'));
    signal lane_trigger_offset  : beat_offset_arr_t := (others => (others => '0'));
    signal result_valid         : std_logic;
    signal result_qualifying    : std_logic;
    signal result_ready         : std_logic := '0';
    signal result_request       : event_request_t;
    signal busy                 : std_logic;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.CNN_RESULT_ARBITER
        port map (
            CLK                 => clk,
            RST                 => rst,
            LANE_VALID          => lane_valid,
            LANE_READY          => lane_ready,
            LANE_SCORE          => lane_score,
            LANE_THRESH         => lane_thresh,
            LANE_START_CHUNK    => lane_start_chunk,
            LANE_START_OFFSET   => lane_start_offset,
            LANE_TIMESTAMP      => lane_timestamp,
            LANE_TRIGGER_OFFSET => lane_trigger_offset,
            RESULT_VALID        => result_valid,
            RESULT_QUALIFY      => result_qualifying,
            RESULT_READY        => result_ready,
            RESULT_REQUEST      => result_request,
            BUSY                => busy
        );

    process
        procedure check_threshold(
            native_score : integer;
            external_threshold : integer;
            expected_qualify : std_logic
        ) is
        begin
            lane_score(0) <= std_logic_vector(to_unsigned(native_score mod 2097152, 32));
            lane_thresh(0) <= std_logic_vector(to_signed(external_threshold, 32));
            lane_valid(0) <= '1';
            wait for 1 ps;
            assert result_valid = '1' and result_qualifying = expected_qualify
                report "external threshold comparison mismatch: score raw=" &
                       integer'image(native_score) & " threshold raw=" &
                       integer'image(external_threshold) severity failure;
            lane_valid(0) <= '0';
            wait for 1 ps;
        end procedure;
    begin
        wait until rising_edge(clk);
        rst <= '0';

        -- External 32 means 2.0, independently of the native 1/512 score unit.
        check_threshold(1024, 32, '0');
        check_threshold(1025, 32, '1');
        check_threshold(1023, 32, '0');
        -- One external step is 0.0625; retain native sub-step precision.
        check_threshold(1055, 33, '0');
        check_threshold(1056, 33, '0');
        check_threshold(1057, 33, '1');
        check_threshold(-1024, -32, '0');
        check_threshold(-1023, -32, '1');
        check_threshold(-1025, -32, '0');
        check_threshold(0, 0, '0');
        check_threshold(1, 0, '1');
        check_threshold(-1, 0, '0');
        -- Native limits and thresholds beyond them must not wrap or clamp.
        check_threshold(-1048576, -32768, '0');
        check_threshold(-1048575, -32768, '1');
        check_threshold(-1048576, -32769, '1');
        check_threshold(1048575, 32768, '0');
        check_threshold(-1048576, -2147483648, '1');
        check_threshold(1048575, 2147483647, '0');

        lane_score(0)  <= std_logic_vector(to_signed(512, 32));
        lane_thresh(0) <= std_logic_vector(to_signed(32, 32));
        lane_score(1)  <= std_logic_vector(to_signed(1536, 32));
        lane_thresh(1) <= std_logic_vector(to_signed(32, 32));
        lane_start_chunk(1)    <= to_unsigned(8, CHUNK_ID_WIDTH);
        lane_start_offset(1)   <= to_unsigned(45, BEAT_OFFSET_WIDTH);
        lane_timestamp(1)      <= to_unsigned(9, TIMESTAMP_WIDTH);
        lane_trigger_offset(1) <= to_unsigned(12, BEAT_OFFSET_WIDTH);
        lane_valid(0) <= '1';
        lane_valid(1) <= '1';
        wait for 1 ps;
        assert lane_ready(0) = '1' and lane_ready(1) = '0' and
               result_valid = '1' and result_qualifying = '0' and busy = '1'
            report "below-threshold score must remain visible without becoming a trigger"
            severity failure;

        wait until rising_edge(clk);
        lane_valid(0) <= '0';
        wait for 1 ps;
        assert result_valid = '1' and result_qualifying = '1' and
               lane_ready(1) = '0'
            report "qualifying result must backpressure its lane" severity failure;
        assert result_request.start_address.chunk_id = to_unsigned(8, CHUNK_ID_WIDTH) and
               result_request.start_address.beat_offset = to_unsigned(45, BEAT_OFFSET_WIDTH) and
               result_request.event_timestamp = to_unsigned(9, TIMESTAMP_WIDTH) and
               result_request.trigger_offset = to_unsigned(12, BEAT_OFFSET_WIDTH) and
               result_request.score = std_logic_vector(to_signed(1536, 32))
            report "arbiter result metadata mismatch" severity failure;

        result_ready <= '1';
        wait until rising_edge(clk);
        lane_valid(1) <= '0';
        result_ready <= '0';

        lane_score(0)  <= x"001FFE00"; -- native -1, zero-padded container
        lane_thresh(0) <= std_logic_vector(to_signed(0, 32));
        lane_valid(0)  <= '1';
        wait for 1 ps;
        assert lane_ready(0) = '1' and result_valid = '1' and
               result_qualifying = '0'
            report "rotation did not advance to the next completed lane" severity failure;

        wait until rising_edge(clk);
        lane_valid(0) <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert busy = '0'
            report "arbiter BUSY did not clear after all lane handshakes" severity failure;

        report "tb_cnn_result_arbiter passed";
        stop;
        wait;
    end process;
end architecture sim;
