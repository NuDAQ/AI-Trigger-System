-- CNN input calibration seam. Both continuous and gated ingress call this
-- stateless, zero-cycle adapter. Replace this implementation to evolve the
-- calibration without coupling it to ring storage or stream control.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.CNN_INPUT_GAIN_PKG.all;
use work.CNN_INPUT_OFFSET_PKG.all;

package CNN_INPUT_CALIBRATION_PKG is
    subtype cnn_native_input_t is signed(9 downto 0);
    subtype cnn_input_channel_t is natural range 0 to 3;
    function cnn_calibrate_adc(raw_code : signed(11 downto 0);
                               channel : cnn_input_channel_t) return cnn_native_input_t;
end package;

package body CNN_INPUT_CALIBRATION_PKG is
    -- These real-valued functions run ONLY while elaborating constants.
    -- model=(raw-baseline)*gain/64; the native input has 5 fractional bits.
    function native_code(raw_code : integer; channel : natural) return integer is
        variable value : real;
    begin
        value := cnn_apply_input_gain(cnn_subtract_input_offset(raw_code, channel), channel) / 2.0;
        if value >= 511.0 then return 511; end if;
        if value <= -511.0 then return -511; end if;
        return integer(floor(value + 0.5)); -- AP_RND: ties toward +infinity
    end function;

    function lookup_bits return positive is
        variable saturated_outside : boolean;
    begin
        -- Adapt the table range when calibration constants are changed.
        -- Defaults need 9 bits; unity gain needs 11. Full 12-bit coverage is
        -- the fallback when the baseline lies outside the ADC range.
        for bits in 2 to 11 loop
            saturated_outside := true;
            for ch in 0 to 3 loop
                if native_code(-(2**(bits-1)), ch) /= -511 or
                   native_code(2**(bits-1)-1, ch) /= 511 then
                    saturated_outside := false;
                end if;
            end loop;
            if saturated_outside then return bits; end if;
        end loop;
        return 12;
    end function;

    constant TABLE_BITS : positive := lookup_bits;
    type channel_table_t is array (0 to 2**TABLE_BITS-1) of cnn_native_input_t;
    type calibration_table_t is array (0 to 3) of channel_table_t;
    function make_tables return calibration_table_t is
        variable result : calibration_table_t;
        variable raw_code : integer;
    begin
        for ch in result'range loop
            for address in result(ch)'range loop
                raw_code := address;
                if address >= 2**(TABLE_BITS-1) then
                    raw_code := address - 2**TABLE_BITS;
                end if;
                result(ch)(address) := to_signed(native_code(raw_code, ch), 10);
            end loop;
        end loop;
        return result;
    end function;
    constant TABLES : calibration_table_t := make_tables;

    function cnn_calibrate_adc(raw_code : signed(11 downto 0);
                               channel : cnn_input_channel_t) return cnn_native_input_t is
    begin
        if raw_code < to_signed(-(2**(TABLE_BITS-1)), 12) then
            return to_signed(-511, 10);
        elsif raw_code > to_signed(2**(TABLE_BITS-1)-1, 12) then
            return to_signed(511, 10);
        end if;
        return TABLES(channel)(to_integer(unsigned(raw_code(TABLE_BITS-1 downto 0))));
    end function;
end package body;
