library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_capture_ctrl is
end entity tb_event_capture_ctrl;

architecture sim of tb_event_capture_ctrl is
    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal data_str         : std_logic := '0';
    signal adc_data4        : adc_data4_t;
    signal chunk_commit     : std_logic;
    signal commit_chunk_id  : chunk_id_t;
    signal trigger_valid    : std_logic := '0';
    signal trigger_ready    : std_logic;
    signal trigger_chunk_id : chunk_id_t := (others => '0');
    signal trigger_score    : std_logic_vector(31 downto 0) := (others => '0');
    signal rb_rd_en         : std_logic;
    signal rb_rd_chunk_id   : chunk_id_t;
    signal rb_rd_batch_idx  : integer range 0 to N_BATCHES - 1;
    signal rb_rd_data       : raw_adc_batch_t;
    signal rb_rd_valid      : std_logic;
    signal rb_rd_hit        : std_logic;
    signal event_valid      : std_logic;
    signal event_ready      : std_logic := '1';
    signal event_data       : raw_adc_batch_t;
    signal event_last       : std_logic;
    signal event_chunk_id   : chunk_id_t;
    signal event_score      : std_logic_vector(31 downto 0);
    signal ring_miss_count  : unsigned(31 downto 0);

    function sample_value(chunk_id : integer; batch_id : integer; ch : integer; sample : integer)
        return std_logic_vector is
        variable v : integer;
    begin
        v := chunk_id * 256 + batch_id * 16 + ch * 4 + sample;
        return std_logic_vector(to_unsigned(v mod 4096, 12));
    end function;

    function expected_batch(chunk_id : integer; batch_id : integer) return raw_adc_batch_t is
        variable packed : raw_adc_batch_t := (others => '0');
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                packed((ch * N_BATCH_S + s) * 12 + 11 downto
                       (ch * N_BATCH_S + s) * 12) :=
                    sample_value(chunk_id, batch_id, ch, s);
            end loop;
        end loop;
        return packed;
    end function;

    procedure drive_batch(signal target : out adc_data4_t; chunk_id : integer; batch_id : integer) is
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                target(ch)(s) <= sample_value(chunk_id, batch_id, ch, s);
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 5 ns;

    u_ring : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK             => clk,
            RST             => rst,
            DATA_STR        => data_str,
            ADC_DATA4       => adc_data4,
            CHUNK_COMMIT    => chunk_commit,
            COMMIT_CHUNK_ID => commit_chunk_id,
            RD_EN           => rb_rd_en,
            RD_CHUNK_ID     => rb_rd_chunk_id,
            RD_BATCH_IDX    => rb_rd_batch_idx,
            RD_DATA         => rb_rd_data,
            RD_VALID        => rb_rd_valid,
            RD_HIT          => rb_rd_hit
        );

    u_capture : entity work.EVENT_CAPTURE_CTRL
        port map (
            CLK              => clk,
            RST              => rst,
            CHUNK_COMMIT     => chunk_commit,
            COMMIT_CHUNK_ID  => commit_chunk_id,
            TRIGGER_VALID    => trigger_valid,
            TRIGGER_READY    => trigger_ready,
            TRIGGER_CHUNK_ID => trigger_chunk_id,
            TRIGGER_SCORE    => trigger_score,
            RB_RD_EN         => rb_rd_en,
            RB_RD_CHUNK_ID   => rb_rd_chunk_id,
            RB_RD_BATCH_IDX  => rb_rd_batch_idx,
            RB_RD_DATA       => rb_rd_data,
            RB_RD_VALID      => rb_rd_valid,
            RB_RD_HIT        => rb_rd_hit,
            EVENT_VALID      => event_valid,
            EVENT_READY      => event_ready,
            EVENT_DATA       => event_data,
            EVENT_LAST       => event_last,
            EVENT_CHUNK_ID   => event_chunk_id,
            EVENT_SCORE      => event_score,
            RING_MISS_COUNT  => ring_miss_count
        );

    process
        variable seen : integer := 0;
        variable chunk_expected : integer;
        variable batch_expected : integer;
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(s) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst <= '0';

        for c in 0 to 1 loop
            for b in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, c, b);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;

        data_str         <= '0';
        trigger_valid    <= '1';
        trigger_chunk_id <= to_unsigned(1, CHUNK_ID_WIDTH);
        trigger_score    <= std_logic_vector(to_signed(2048, 32));
        wait until rising_edge(clk);
        trigger_valid <= '0';

        for b in 0 to N_BATCHES - 1 loop
            drive_batch(adc_data4, 2, b);
            data_str <= '1';
            wait until rising_edge(clk);
        end loop;
        data_str <= '0';

        while seen < EVENT_CHUNKS * N_BATCHES loop
            wait until rising_edge(clk);
            wait for 1 ns;
            if event_valid = '1' then
                chunk_expected := seen / N_BATCHES;
                batch_expected := seen mod N_BATCHES;
                assert event_chunk_id = to_unsigned(1, CHUNK_ID_WIDTH)
                    report "event metadata chunk id mismatch"
                    severity failure;
                assert event_score = std_logic_vector(to_signed(2048, 32))
                    report "event metadata score mismatch"
                    severity failure;
                assert event_data = expected_batch(chunk_expected, batch_expected)
                    report "event waveform batch mismatch"
                    severity failure;
                if seen = EVENT_CHUNKS * N_BATCHES - 1 then
                    assert event_last = '1'
                        report "last event batch must assert event_last"
                        severity failure;
                else
                    assert event_last = '0'
                        report "non-final event batch must not assert event_last"
                        severity failure;
                end if;
                seen := seen + 1;
            end if;
        end loop;

        report "tb_event_capture_ctrl passed";
        stop;
    end process;
end architecture sim;
