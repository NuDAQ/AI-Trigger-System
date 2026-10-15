-- Static CNN-only gain configuration. Edit these four values, then rebuild.
-- One million means unity gain; no stream/control code needs to change.
library ieee;
use ieee.std_logic_1164.all;

package CNN_INPUT_GAIN_PKG is
    type cnn_gain_ppm_array_t is array (0 to 3) of positive;
    constant CNN_INPUT_GAIN_PPM : cnn_gain_ppm_array_t := (
        0 => 4_421_578,
        1 => 4_475_522,
        2 => 4_417_241,
        3 => 4_400_045
    );
    -- Elaboration-only arithmetic, folded into the calibration lookup.
    function cnn_apply_input_gain(value : real; channel : natural) return real;
end package;

package body CNN_INPUT_GAIN_PKG is
    function cnn_apply_input_gain(value : real; channel : natural) return real is
    begin
        return value * real(CNN_INPUT_GAIN_PPM(channel)) / 1_000_000.0;
    end function;
end package body;
