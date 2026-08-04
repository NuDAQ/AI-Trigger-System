library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_gated_cnn_reader is
end entity tb_gated_cnn_reader;

architecture sim of tb_gated_cnn_reader is
    constant LANE_TWO : std_logic_vector(N_LANES - 1 downto 0) := "00100";
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal work_valid           : std_logic := '0';
    signal work_ready           : std_logic;
    signal work_value           : event_request_t := NULL_EVENT_REQUEST;
    signal cnn_thresh           : std_logic_vector(31 downto 0) := x"00000123";
    signal lane_busy            : lane_busy_t := (others => '1');
    signal check_start_chunk_id : chunk_id_t;
    signal check_start_offset   : beat_offset_t;
    signal check_present        : std_logic := '1';
    signal check_protected      : std_logic := '1';
    signal check_expired        : std_logic := '0';
    signal ring_request         : std_logic;
    signal ring_grant           : std_logic := '0';
    signal ring_done            : std_logic;
    signal rb_rd_en             : std_logic;
    signal rb_rd_chunk_id       : chunk_id_t;
    signal rb_rd_batch_idx      : integer range 0 to N_BATCHES - 1;
    signal rb_rd_data           : raw_adc_batch_t := (others => '0');
    signal rb_rd_valid          : std_logic := '0';
    signal rb_rd_hit            : std_logic := '0';
    signal lane_we              : std_logic_vector(N_LANES - 1 downto 0);
    signal batch_data           : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
    signal lane_start_chunk     : chunk_id_t;
    signal lane_start_offset    : beat_offset_t;
    signal lane_timestamp       : timestamp_t;
    signal lane_trigger_offset  : beat_offset_t;
    signal lane_thresh          : std_logic_vector(31 downto 0);
    signal busy                 : std_logic;
    signal event_loss_pulse     : std_logic;

    function raw_for(address_value : logical_beat_t) return raw_adc_batch_t is
        variable result : raw_adc_batch_t := (others => '0');
        variable value  : integer;
    begin
        value := (to_integer(address_value.chunk_id) * N_BATCHES +
                  to_integer(address_value.beat_offset)) mod 2048;
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                result((ch * N_BATCH_S + sample_idx) * 12 + 11 downto
                       (ch * N_BATCH_S + sample_idx) * 12) :=
                    std_logic_vector(to_signed(value + ch + sample_idx, 12));
            end loop;
        end loop;
        return result;
    end function;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.GATED_CNN_READER
        port map (
            CLK                  => clk,
            RST                  => rst,
            WORK_VALID           => work_valid,
            WORK_READY           => work_ready,
            WORK_VALUE           => work_value,
            CNN_THRESH           => cnn_thresh,
            LANE_BUSY            => lane_busy,
            CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET   => check_start_offset,
            CHECK_PRESENT        => check_present,
            CHECK_PROTECTED      => check_protected,
            CHECK_EXPIRED        => check_expired,
            RING_REQUEST         => ring_request,
            RING_GRANT           => ring_grant,
            RING_DONE            => ring_done,
            RB_RD_EN             => rb_rd_en,
            RB_RD_CHUNK_ID       => rb_rd_chunk_id,
            RB_RD_BATCH_IDX      => rb_rd_batch_idx,
            RB_RD_DATA           => rb_rd_data,
            RB_RD_VALID          => rb_rd_valid,
            RB_RD_HIT            => rb_rd_hit,
            LANE_WE              => lane_we,
            BATCH_DATA           => batch_data,
            LANE_START_CHUNK     => lane_start_chunk,
            LANE_START_OFFSET    => lane_start_offset,
            LANE_TIMESTAMP       => lane_timestamp,
            LANE_TRIGGER_OFFSET  => lane_trigger_offset,
            LANE_THRESH          => lane_thresh,
            BUSY                 => busy,
            EVENT_LOSS_PULSE     => event_loss_pulse
        );

    ring_model : process (clk)
        variable address_value : logical_beat_t;
    begin
        if rising_edge(clk) then
            rb_rd_valid <= rb_rd_en;
            rb_rd_hit   <= rb_rd_en;
            if rb_rd_en = '1' then
                address_value.chunk_id    := rb_rd_chunk_id;
                address_value.beat_offset := to_unsigned(rb_rd_batch_idx, BEAT_OFFSET_WIDTH);
                rb_rd_data <= raw_for(address_value);
            end if;
        end if;
    end process;

    process
        variable issued_address : logical_beat_t;
        variable issued_count   : integer := 0;
        variable written_count  : integer := 0;
    begin
        lane_busy(2) <= '0';
        work_value.start_address.chunk_id    <= to_unsigned(4, CHUNK_ID_WIDTH);
        work_value.start_address.beat_offset <= to_unsigned(45, BEAT_OFFSET_WIDTH);
        work_value.event_timestamp           <= to_unsigned(5, TIMESTAMP_WIDTH);
        work_value.trigger_offset            <= to_unsigned(12, BEAT_OFFSET_WIDTH);
        work_value.score                     <= (others => '0');

        wait until rising_edge(clk);
        rst <= '0';
        work_valid <= '1';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert ring_request = '1' and work_ready = '0'
            report "protected gated work must request the ring without completing early" severity failure;
        assert check_start_chunk_id = to_unsigned(4, CHUNK_ID_WIDTH) and
               check_start_offset = to_unsigned(45, BEAT_OFFSET_WIDTH)
            report "gated preflight address mismatch" severity failure;

        ring_grant <= '1';
        while work_ready = '0' loop
            wait until falling_edge(clk);
            if rb_rd_en = '1' then
                issued_address.chunk_id := rb_rd_chunk_id;
                issued_address.beat_offset := to_unsigned(rb_rd_batch_idx, BEAT_OFFSET_WIDTH);
                assert issued_address = add_beats(work_value.start_address, issued_count)
                    report "gated ring read address sequence mismatch" severity failure;
                issued_count := issued_count + 1;
            end if;
            if lane_we /= (lane_we'range => '0') then
                assert lane_we = LANE_TWO
                    report "gated work was not reserved on the selected free lane" severity failure;
                assert batch_data = pack_cnn_raw_batch(rb_rd_data)
                    report "gated reader did not use the shared CNN packer" severity failure;
                written_count := written_count + 1;
            end if;
        end loop;

        assert issued_count = N_BATCHES and written_count = N_BATCHES
            report "gated reader did not transfer one complete CNN window" severity failure;
        assert ring_done = '1' and lane_start_chunk = to_unsigned(4, CHUNK_ID_WIDTH) and
               lane_start_offset = to_unsigned(45, BEAT_OFFSET_WIDTH) and
               lane_timestamp = to_unsigned(5, TIMESTAMP_WIDTH) and
               lane_trigger_offset = to_unsigned(12, BEAT_OFFSET_WIDTH) and
               lane_thresh = x"00000123"
            report "gated lane metadata or completion pulse mismatch" severity failure;

        wait until rising_edge(clk);
        work_valid <= '0';
        ring_grant <= '0';
        wait until rising_edge(clk);
        wait for 1 ps;
        assert busy = '0' and event_loss_pulse = '0'
            report "gated reader did not return idle cleanly" severity failure;

        report "tb_gated_cnn_reader passed";
        stop;
        wait;
    end process;
end architecture sim;
