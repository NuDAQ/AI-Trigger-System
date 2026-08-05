library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;
use work.PRE_TRIGGER_pkg.all;

entity tb_hilo_input_adapter is
end entity tb_hilo_input_adapter;

architecture sim of tb_hilo_input_adapter is
    signal clk               : std_logic := '0';
    signal rst               : std_logic := '1';
    signal mode_start        : std_logic := '0';
    signal enable            : std_logic := '0';
    signal data_str          : std_logic := '0';
    signal adc_data4         : work.AI_TRIGGER_PKG.adc_data4_t;
    signal write_chunk_id    : chunk_id_t := (others => '0');
    signal write_beat_offset : beat_offset_t := (others => '0');
    signal write_timestamp   : timestamp_t := (others => '0');
    signal hl_data_str       : std_logic;
    signal hl_adc_data4      : adc_data4_type;
    signal hl_anchor_chunk   : chunk_id_t;
    signal hl_anchor_offset  : beat_offset_t;
    signal hl_anchor_time    : timestamp_t;
    signal busy              : std_logic;

    procedure drive_beat(
        signal target : out work.AI_TRIGGER_PKG.adc_data4_t;
        beat_value    : integer
    ) is
    begin
        for ch in 0 to N_TRIGGER_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                target(ch)(sample_idx) <= std_logic_vector(to_unsigned(
                    ch * 100 + beat_value * 4 + sample_idx, 12));
            end loop;
        end loop;
    end procedure;
begin
    clk <= not clk after 2 ns;

    u_dut : entity work.HILO_INPUT_ADAPTER
        port map (
            CLK               => clk,
            RST               => rst,
            MODE_START        => mode_start,
            ENABLE            => enable,
            DATA_STR          => data_str,
            ADC_DATA4         => adc_data4,
            WRITE_CHUNK_ID    => write_chunk_id,
            WRITE_BEAT_OFFSET => write_beat_offset,
            WRITE_TIMESTAMP   => write_timestamp,
            HL_DATA_STR       => hl_data_str,
            HL_ADC_DATA4      => hl_adc_data4,
            HL_ANCHOR_CHUNK   => hl_anchor_chunk,
            HL_ANCHOR_OFFSET  => hl_anchor_offset,
            HL_ANCHOR_TIME    => hl_anchor_time,
            BUSY              => busy
        );

    process
    begin
        for ch in 0 to N_ADC_CH - 1 loop
            for sample_idx in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(sample_idx) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst    <= '0';
        enable <= '1';

        for beat in 0 to 2 loop
            drive_beat(adc_data4, beat);
            write_beat_offset <= to_unsigned(beat, BEAT_OFFSET_WIDTH);
            data_str <= '1';
            wait until rising_edge(clk);
            data_str <= '0';
            wait until rising_edge(clk);
            wait for 1 ps;
            assert hl_data_str = '0' and busy = '1'
                report "Hi-Lo adapter emitted an incomplete aggregate" severity failure;
        end loop;

        drive_beat(adc_data4, 3);
        write_chunk_id    <= to_unsigned(7, CHUNK_ID_WIDTH);
        write_beat_offset <= to_unsigned(19, BEAT_OFFSET_WIDTH);
        write_timestamp   <= to_unsigned(77, TIMESTAMP_WIDTH);
        data_str <= '1';
        wait until rising_edge(clk);
        data_str <= '0';
        wait for 1 ps;
        assert hl_data_str = '1' and busy = '0'
            report "four accepted beats must produce one registered Hi-Lo batch" severity failure;
        assert hl_anchor_chunk = to_unsigned(7, CHUNK_ID_WIDTH) and
               hl_anchor_offset = to_unsigned(19, BEAT_OFFSET_WIDTH) and
               hl_anchor_time = to_unsigned(77, TIMESTAMP_WIDTH)
            report "Hi-Lo adapter anchor must identify the fourth input beat" severity failure;
        for ch in 0 to N_TRIGGER_CH - 1 loop
            for sample_idx in 0 to 15 loop
                assert hl_adc_data4(ch)(sample_idx) = std_logic_vector(to_unsigned(
                    ch * 100 + sample_idx, 12))
                    report "Hi-Lo adapter sample order mismatch" severity failure;
            end loop;
        end loop;

        wait until rising_edge(clk);
        wait for 1 ps;
        assert hl_data_str = '0'
            report "Hi-Lo adapter DATA_STR must be a one-cycle pulse" severity failure;

        drive_beat(adc_data4, 0);
        data_str <= '1';
        wait until rising_edge(clk);
        data_str   <= '0';
        mode_start <= '1';
        wait until rising_edge(clk);
        mode_start <= '0';
        wait for 1 ps;
        assert busy = '0' and hl_data_str = '0'
            report "mode entry must discard a partial Hi-Lo aggregate" severity failure;

        report "tb_hilo_input_adapter passed";
        stop;
        wait;
    end process;
end architecture sim;
