library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.AI_TRIGGER_PKG.all;

entity tb_cnn_input_conversion is
    generic (REFERENCE_FILE : string := "");
end entity;

architecture test of tb_cnn_input_conversion is
begin
    process
        file native_table : text;
        variable row : line;
        variable expected : integer;
        type integer_array_t is array (natural range <>) of integer;
        -- Worked channel-zero examples with fractional baseline before gain.
        constant raw_codes : integer_array_t :=
            (-2048, -1024, -233, -232, -231, -170, -169, -32, -5, -4, -3, -2, -1,
             0, 1, 2, 3, 4, 5, 32, 169, 170, 231, 232, 233, 1024, 2047);
        constant native_codes : integer_array_t :=
            (-511, -511, -510, -508, -505, -371, -368, -65, -6, -4, -1, 1, 3, 5, 8, 10, 12, 14, 16, 76, 379, 381, 511, 511, 511, 511, 511);
    begin
        for i in raw_codes'range loop
            assert signed(adc_to_axis16(std_logic_vector(to_signed(raw_codes(i), 12)))) =
                to_signed(native_codes(i), 16)
                report "Native CNN conversion mismatch at raw=" & integer'image(raw_codes(i))
                severity failure;
        end loop;
        if REFERENCE_FILE /= "" then
            file_open(native_table, REFERENCE_FILE, read_mode);
            for channel in 0 to 3 loop
            for raw in -2048 to 2047 loop
                assert not endfile(native_table) report "incomplete native table" severity failure;
                readline(native_table, row);
                read(row, expected);
                assert to_integer(signed(adc_to_axis16(std_logic_vector(to_signed(raw,12)), channel))) = expected
                    report "native table mismatch at raw=" & integer'image(raw) severity failure;
            end loop;
            end loop;
            assert endfile(native_table) report "extra native table entries" severity failure;
            file_close(native_table);
        end if;
        report "Native CNN input conversion passed";
        stop;
        wait;
    end process;
end architecture;
