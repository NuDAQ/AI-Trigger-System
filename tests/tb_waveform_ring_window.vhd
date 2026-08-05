library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_waveform_ring_window is
end entity tb_waveform_ring_window;

architecture sim of tb_waveform_ring_window is
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal data_str             : std_logic := '0';
    signal adc_data4            : adc_data4_t;
    signal chunk_commit         : std_logic;
    signal commit_chunk_id      : chunk_id_t;
    signal commit_timestamp     : timestamp_t;
    signal write_chunk_id       : chunk_id_t;
    signal write_beat_offset    : beat_offset_t;
    signal write_timestamp      : timestamp_t;
    signal check_start_chunk_id : chunk_id_t := (others => '0');
    signal check_start_offset   : beat_offset_t := (others => '0');
    signal check_present        : std_logic;
    signal check_protected      : std_logic;
    signal check_expired        : std_logic;
    signal rd_en                : std_logic := '0';
    signal rd_chunk_id          : chunk_id_t := (others => '0');
    signal rd_batch_idx         : integer range 0 to N_BATCHES - 1 := 0;
    signal rd_data              : raw_adc_batch_t;
    signal rd_valid             : std_logic;
    signal rd_hit               : std_logic;

    procedure drive_batch(
        signal target : out adc_data4_t;
        chunk_value   : integer;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    (chunk_value * 64 + beat_value) mod 4096, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK                  => clk,
            RST                  => rst,
            DATA_STR             => data_str,
            ADC_DATA4            => adc_data4,
            CHUNK_COMMIT         => chunk_commit,
            COMMIT_CHUNK_ID      => commit_chunk_id,
            COMMIT_TIMESTAMP     => commit_timestamp,
            WRITE_CHUNK_ID       => write_chunk_id,
            WRITE_BEAT_OFFSET    => write_beat_offset,
            WRITE_TIMESTAMP      => write_timestamp,
            CHECK_START_CHUNK_ID => check_start_chunk_id,
            CHECK_START_OFFSET   => check_start_offset,
            CHECK_PRESENT        => check_present,
            CHECK_PROTECTED      => check_protected,
            CHECK_EXPIRED        => check_expired,
            RD_EN                => rd_en,
            RD_CHUNK_ID          => rd_chunk_id,
            RD_BATCH_IDX         => rd_batch_idx,
            RD_DATA              => rd_data,
            RD_VALID             => rd_valid,
            RD_HIT               => rd_hit
        );

    process
        variable address_value : logical_beat_t;
        variable seen          : integer := 0;
        variable expected      : integer;
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(sample_idx) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst <= '0';

        for chunk_value in 0 to 1 loop
            for beat_value in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, chunk_value, beat_value);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';
        wait for 1 ps;

        assert commit_chunk_id = to_unsigned(1, CHUNK_ID_WIDTH) and
               commit_timestamp = to_unsigned(1, TIMESTAMP_WIDTH)
            report "ring commit metadata is not aligned" severity failure;
        assert write_chunk_id = to_unsigned(2, CHUNK_ID_WIDTH) and
               write_beat_offset = to_unsigned(0, BEAT_OFFSET_WIDTH) and
               write_timestamp = to_unsigned(2, TIMESTAMP_WIDTH)
            report "next accepted-beat identity is wrong" severity failure;

        check_start_chunk_id <= to_unsigned(0, CHUNK_ID_WIDTH);
        check_start_offset   <= to_unsigned(40, BEAT_OFFSET_WIDTH);
        wait for 1 ps;
        assert check_present = '1' and check_protected = '1' and
               check_expired = '0'
            report "a complete young cross-chunk window must pass preflight" severity failure;

        address_value.chunk_id    := to_unsigned(0, CHUNK_ID_WIDTH);
        address_value.beat_offset := to_unsigned(40, BEAT_OFFSET_WIDTH);
        for beat in 0 to N_BATCHES - 1 loop
            rd_chunk_id  <= address_value.chunk_id;
            rd_batch_idx <= to_integer(address_value.beat_offset);
            rd_en        <= '1';
            wait until rising_edge(clk);
            address_value := add_beats(address_value, 1);

            if rd_valid = '1' then
                expected := 40 + seen;
                assert rd_hit = '1'
                    report "preflighted ring read missed" severity failure;
                assert to_integer(unsigned(rd_data(11 downto 0))) = expected
                    report "cross-chunk ring data order mismatch" severity failure;
                seen := seen + 1;
            end if;
        end loop;
        rd_en <= '0';
        wait until rising_edge(clk);
        if rd_valid = '1' then
            expected := 40 + seen;
            assert rd_hit = '1' and
                   to_integer(unsigned(rd_data(11 downto 0))) = expected
                report "final cross-chunk ring response mismatch" severity failure;
            seen := seen + 1;
        end if;
        assert seen = N_BATCHES
            report "cross-chunk ring read did not return 64 beats" severity failure;

        for chunk_value in 2 to WAVEFORM_RING_DEPTH - 1 loop
            for beat_value in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, chunk_value, beat_value);
                data_str <= '1';
                wait until rising_edge(clk);
            end loop;
        end loop;
        data_str <= '0';
        wait for 1 ps;
        assert check_present = '1' and check_protected = '0' and
               check_expired = '1'
            report "a window without overwrite margin must fail preflight" severity failure;

        report "tb_waveform_ring_window passed";
        stop;
        wait;
    end process;
end architecture sim;
