-- Static CNN-only baseline configuration, BEFORE gain. Edit and rebuild.
-- These are measured baselines to SUBTRACT, in microvolts. Zero disables
-- baseline correction. Retain fractional ADC codes until native quantization.
package CNN_INPUT_OFFSET_PKG is
    constant CNN_ADC_FULL_SCALE_UV_PP : positive := 800_000;
    type cnn_offset_uv_array_t is array (0 to 3) of integer;
    constant CNN_INPUT_OFFSET_UV : cnn_offset_uv_array_t := (
        0 => -468,
        1 => -14,
        2 => 1_118,
        3 => 585
    );
    -- Elaboration-only arithmetic, folded into the calibration lookup.
    function cnn_subtract_input_offset(raw_code : integer; channel : natural) return real;
end package;

package body CNN_INPUT_OFFSET_PKG is
    function cnn_subtract_input_offset(raw_code : integer; channel : natural) return real is
    begin
        return real(raw_code) - real(CNN_INPUT_OFFSET_UV(channel)) *
               4096.0 / real(CNN_ADC_FULL_SCALE_UV_PP);
    end function;
end package body;
