library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_ring_read_arbiter is
end entity tb_ring_read_arbiter;

architecture sim of tb_ring_read_arbiter is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal event_check_valid : std_logic := '0';
    signal event_check_chunk : chunk_id_t := (others => '0');
    signal event_check_offset : beat_offset_t := (others => '0');
    signal event_check_present, event_check_protected, event_check_expired : std_logic;
    signal gated_check_valid : std_logic := '0';
    signal gated_check_chunk : chunk_id_t := (others => '0');
    signal gated_check_offset : beat_offset_t := (others => '0');
    signal gated_check_present, gated_check_protected, gated_check_expired : std_logic;
    signal shared_check_chunk : chunk_id_t;
    signal shared_check_offset : beat_offset_t;
    signal shared_check_present : std_logic := '1';
    signal shared_check_protected : std_logic := '1';
    signal shared_check_expired : std_logic := '0';
    signal event_request, event_grant, event_done, event_continue, event_owner_active : std_logic := '0';
    signal gated_request, gated_grant, gated_done : std_logic := '0';
    signal event_rd_en : std_logic := '0';
    signal event_rd_chunk : chunk_id_t := (others => '0');
    signal event_rd_idx : integer range 0 to N_BATCHES - 1 := 0;
    signal gated_rd_en : std_logic := '0';
    signal gated_rd_chunk : chunk_id_t := (others => '0');
    signal gated_rd_idx : integer range 0 to N_BATCHES - 1 := 0;
    signal shared_rd_en : std_logic;
    signal shared_rd_chunk : chunk_id_t;
    signal shared_rd_idx : integer range 0 to N_BATCHES - 1;
    signal shared_rd_data : raw_adc_batch_t := (others => '0');
    signal shared_rd_valid : std_logic := '0';
    signal shared_rd_hit : std_logic := '1';
    signal event_rd_valid, event_rd_hit : std_logic;
    signal gated_rd_valid, gated_rd_hit : std_logic;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.RING_READ_ARBITER
        port map (
            CLK => clk, RST => rst,
            EVENT_CHECK_VALID => event_check_valid,
            EVENT_CHECK_CHUNK => event_check_chunk,
            EVENT_CHECK_OFFSET => event_check_offset,
            EVENT_CHECK_PRESENT => event_check_present,
            EVENT_CHECK_PROTECTED => event_check_protected,
            EVENT_CHECK_EXPIRED => event_check_expired,
            GATED_CHECK_VALID => gated_check_valid,
            GATED_CHECK_CHUNK => gated_check_chunk,
            GATED_CHECK_OFFSET => gated_check_offset,
            GATED_CHECK_PRESENT => gated_check_present,
            GATED_CHECK_PROTECTED => gated_check_protected,
            GATED_CHECK_EXPIRED => gated_check_expired,
            SHARED_CHECK_CHUNK => shared_check_chunk,
            SHARED_CHECK_OFFSET => shared_check_offset,
            SHARED_CHECK_PRESENT => shared_check_present,
            SHARED_CHECK_PROTECTED => shared_check_protected,
            SHARED_CHECK_EXPIRED => shared_check_expired,
            EVENT_REQUEST => event_request,
            EVENT_GRANT => event_grant,
            EVENT_DONE => event_done,
            EVENT_CONTINUE => event_continue,
            EVENT_OWNER_ACTIVE => event_owner_active,
            GATED_REQUEST => gated_request,
            GATED_GRANT => gated_grant,
            GATED_DONE => gated_done,
            EVENT_RD_EN => event_rd_en,
            EVENT_RD_CHUNK => event_rd_chunk,
            EVENT_RD_IDX => event_rd_idx,
            EVENT_RD_VALID => event_rd_valid,
            EVENT_RD_HIT => event_rd_hit,
            GATED_RD_EN => gated_rd_en,
            GATED_RD_CHUNK => gated_rd_chunk,
            GATED_RD_IDX => gated_rd_idx,
            GATED_RD_VALID => gated_rd_valid,
            GATED_RD_HIT => gated_rd_hit,
            SHARED_RD_EN => shared_rd_en,
            SHARED_RD_CHUNK => shared_rd_chunk,
            SHARED_RD_IDX => shared_rd_idx,
            SHARED_RD_DATA => shared_rd_data,
            SHARED_RD_VALID => shared_rd_valid,
            SHARED_RD_HIT => shared_rd_hit
        );

    process
    begin
        wait until rising_edge(clk);
        rst <= '0';
        event_check_valid <= '1';
        event_check_chunk <= to_unsigned(10, CHUNK_ID_WIDTH);
        event_check_offset <= to_unsigned(3, BEAT_OFFSET_WIDTH);
        gated_check_valid <= '1';
        gated_check_chunk <= to_unsigned(20, CHUNK_ID_WIDTH);
        gated_check_offset <= to_unsigned(4, BEAT_OFFSET_WIDTH);
        event_request <= '1';
        gated_request <= '1';
        wait for 1 ps;
        assert shared_check_chunk = to_unsigned(10, CHUNK_ID_WIDTH) and
               event_check_present = '1' and gated_check_present = '0'
            report "event preflight must have priority" severity failure;
        assert event_grant = '1' and gated_grant = '0'
            report "event ring request must win idle arbitration" severity failure;

        event_owner_active <= '1';
        event_rd_en <= '1';
        event_rd_chunk <= to_unsigned(11, CHUNK_ID_WIDTH);
        event_rd_idx <= 5;
        wait until rising_edge(clk);
        wait for 1 ps;
        assert shared_rd_en = '1' and shared_rd_chunk = to_unsigned(11, CHUNK_ID_WIDTH) and
               shared_rd_idx = 5 and gated_grant = '0'
            report "event owner did not retain the non-preemptive read port" severity failure;

        event_rd_en <= '0';
        event_check_valid <= '0';
        event_request <= '0';
        event_owner_active <= '0';
        event_done <= '1';
        wait until rising_edge(clk);
        event_done <= '0';
        wait for 1 ps;
        assert gated_grant = '1'
            report "gated transaction did not acquire the ring after event completion" severity failure;

        wait until rising_edge(clk);
        gated_rd_en <= '1';
        gated_rd_chunk <= to_unsigned(21, CHUNK_ID_WIDTH);
        gated_rd_idx <= 6;
        event_request <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert gated_grant = '1' and event_grant = '0' and
               shared_rd_chunk = to_unsigned(21, CHUNK_ID_WIDTH)
            report "an event request preempted an active gated transaction" severity failure;

        gated_done <= '1';
        gated_rd_en <= '0';
        wait until rising_edge(clk);
        gated_done <= '0';
        wait for 1 ps;
        assert event_grant = '1'
            report "pending event did not win after gated completion" severity failure;

        report "tb_ring_read_arbiter passed";
        stop;
        wait;
    end process;
end architecture sim;
