library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_cnn_input_conversion is
end entity;

architecture test of tb_cnn_input_conversion is
begin
    process
        type integer_array_t is array (natural range <>) of integer;
        -- Worked AP_RND (ties toward +infinity), AP_SAT_SYM examples at raw/64.
        constant raw_codes : integer_array_t :=
            (-2048, -1024, -1023, -1022, -1021, -513, -3, -2, -1,
             0, 1, 2, 3, 511, 512, 513, 1020, 1021, 1022, 1023, 2047);
        constant native_codes : integer_array_t :=
            (-511, -511, -511, -511, -510, -256, -1, -1, 0,
             0, 1, 1, 2, 256, 256, 257, 510, 511, 511, 511, 511);
    begin
        for i in raw_codes'range loop
            assert signed(adc_to_axis16(std_logic_vector(to_signed(raw_codes(i), 12)))) =
                to_signed(native_codes(i), 16)
                report "Native CNN conversion mismatch at raw=" & integer'image(raw_codes(i))
                severity failure;
        end loop;
        report "Native CNN input conversion passed";
        stop;
        wait;
    end process;
end architecture;
