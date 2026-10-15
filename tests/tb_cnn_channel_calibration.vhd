library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_cnn_channel_calibration is
end entity;

architecture test of tb_cnn_channel_calibration is
begin
    process
        variable adc : adc_data4_t := (others => (others => (others => '0')));
        variable raw_batch : raw_adc_batch_t := (others => '0');
        variable packed : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0);
        type expected_row_t is array (0 to 3) of integer;
        -- Worked physical-scale examples, independent of the RTL table.
        constant zero_expected : expected_row_t := (5, 0, -13, -7);
        constant sample_expected : expected_row_t := (76, 72, 58, 64);
        variable expected : integer;
    begin
        for sample_idx in 0 to 3 loop
            for ch in 0 to 7 loop
                if sample_idx mod 2 = 0 then
                    adc(ch)(sample_idx) := std_logic_vector(to_signed(0, 12));
                else
                    adc(ch)(sample_idx) := std_logic_vector(to_signed(32, 12));
                end if;
                raw_batch((ch*4+sample_idx)*12+11 downto (ch*4+sample_idx)*12) :=
                    adc(ch)(sample_idx);
            end loop;
        end loop;
        packed := pack_cnn_batch(adc);
        for sample_idx in 0 to 3 loop
            for ch in 0 to 3 loop
                if sample_idx mod 2 = 0 then
                    expected := zero_expected(ch);
                else
                    expected := sample_expected(ch);
                end if;
                assert to_integer(signed(packed((sample_idx*4+ch)*16+15 downto
                                               (sample_idx*4+ch)*16))) = expected
                    report "CNN calibration mismatch ch=" & integer'image(ch) &
                           " sample=" & integer'image(sample_idx)
                    severity failure;
            end loop;
        end loop;
        assert pack_cnn_raw_batch(raw_batch) = packed
            report "continuous and gated CNN calibration differ" severity failure;
        report "PASS channel-specific CNN gain/offset through both input packers";
        stop;
        wait;
    end process;
end architecture;
