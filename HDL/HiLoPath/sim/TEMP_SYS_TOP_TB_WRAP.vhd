-- =============================================================================
-- TEMP_SYS_TOP_TB_WRAP.vhd
-- Simulation-only VHDL wrapper for tb_temp_sys_top.sv (mixed-language bridge).
--
-- Vivado xsim cannot connect a SystemVerilog signal to a VHDL port of a
-- user-defined composite type (e.g. adc_data8_type).  This wrapper exposes
-- a flat std_logic_vector(1535 downto 0) instead (8 * 16 * 12 = 1536 bits)
-- and unpacks it back to adc_data8_type before driving TEMP_SYS_TOP.
--
-- Bit packing (must match the SV generate block in tb_temp_sys_top.sv):
--   adc_data_tb[ch][s]  <->  ADC_DATA8_FLAT(1535 - (ch*16+s)*12 downto
--                                            1524 - (ch*16+s)*12)
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.pre_trigger_pkg.all;

entity TEMP_SYS_TOP_TB_WRAP is
    port (
        CLK_FAST       : in  std_logic;
        CLK_SLOW       : in  std_logic;
        SYS_RST        : in  std_logic;
        DATA_STR       : in  std_logic;
        -- Flat replacement for adc_data8_type (8 channels * 16 samples * 12 bits)
        ADC_DATA8_FLAT : in  std_logic_vector(1535 downto 0);
        L0_PRE_TRIG    : out std_logic;
        CNN_OUT_DATA   : out std_logic_vector(31 downto 0);
        CNN_OUT_VALID  : out std_logic;
        CNN_OUT_READY  : in  std_logic
    );
end entity TEMP_SYS_TOP_TB_WRAP;

architecture rtl of TEMP_SYS_TOP_TB_WRAP is

    signal adc_internal : adc_data8_type;

begin

    -- Unpack the flat vector into the 2-D array.
    -- Outer index (ch): 0 to 7   -> high bits first
    -- Inner index (s):  0 to 15  -> high bits first within each channel
    gen_ch : for ch in 0 to 7 generate
        gen_s : for s in 0 to 15 generate
            adc_internal(ch)(s) <=
                ADC_DATA8_FLAT(1535 - (ch * 16 + s) * 12 downto
                               1524 - (ch * 16 + s) * 12);
        end generate gen_s;
    end generate gen_ch;

    u_dut : entity work.TEMP_SYS_TOP
        port map (
            CLK_FAST      => CLK_FAST,
            CLK_SLOW      => CLK_SLOW,
            SYS_RST       => SYS_RST,
            DATA_STR      => DATA_STR,
            ADC_DATA8     => adc_internal,
            L0_PRE_TRIG   => L0_PRE_TRIG,
            CNN_OUT_DATA  => CNN_OUT_DATA,
            CNN_OUT_VALID => CNN_OUT_VALID,
            CNN_OUT_READY => CNN_OUT_READY
        );

end architecture rtl;
