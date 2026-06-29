library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_waveform_ring_buffer is
end entity tb_waveform_ring_buffer;

architecture sim of tb_waveform_ring_buffer is
    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal data_str        : std_logic := '0';
    signal adc_data4       : adc_data4_t;
    signal chunk_commit    : std_logic;
    signal commit_chunk_id : chunk_id_t;
    signal rd_en           : std_logic := '0';
    signal rd_chunk_id     : chunk_id_t := (others => '0');
    signal rd_batch_idx    : integer range 0 to N_BATCHES - 1 := 0;
    signal rd_data         : raw_adc_batch_t;
    signal rd_valid        : std_logic;
    signal rd_hit          : std_logic;

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

    u_dut : entity work.WAVEFORM_RING_BUFFER
        port map (
            CLK             => clk,
            RST             => rst,
            DATA_STR        => data_str,
            ADC_DATA4       => adc_data4,
            CHUNK_COMMIT    => chunk_commit,
            COMMIT_CHUNK_ID => commit_chunk_id,
            RD_EN           => rd_en,
            RD_CHUNK_ID     => rd_chunk_id,
            RD_BATCH_IDX    => rd_batch_idx,
            RD_DATA         => rd_data,
            RD_VALID        => rd_valid,
            RD_HIT          => rd_hit
        );

    process
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                adc_data4(ch)(s) <= (others => '0');
            end loop;
        end loop;

        wait until rising_edge(clk);
        rst <= '0';

        for c in 0 to 2 loop
            for b in 0 to N_BATCHES - 1 loop
                drive_batch(adc_data4, c, b);
                data_str <= '1';
                wait until rising_edge(clk);
                if b = N_BATCHES - 1 then
                    wait for 1 ns;
                    assert chunk_commit = '1'
                        report "ring buffer must report completed chunks"
                        severity failure;
                    assert commit_chunk_id = to_unsigned(c, CHUNK_ID_WIDTH)
                        report "commit chunk id mismatch"
                        severity failure;
                end if;
            end loop;
        end loop;
        data_str <= '0';

        rd_chunk_id  <= to_unsigned(1, CHUNK_ID_WIDTH);
        rd_batch_idx <= 9;
        rd_en        <= '1';
        wait until rising_edge(clk);
        rd_en <= '0';
        wait for 1 ns;

        assert rd_valid = '1'
            report "read must return a valid pulse"
            severity failure;
        assert rd_hit = '1'
            report "read must hit a retained chunk"
            severity failure;
        assert rd_data = expected_batch(1, 9)
            report "read batch data mismatch"
            severity failure;

        report "tb_waveform_ring_buffer passed";
        stop;
    end process;
end architecture sim;
