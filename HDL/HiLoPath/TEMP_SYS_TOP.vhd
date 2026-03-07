library ieee;
use ieee.std_logic_1164.all;
use work.pre_trigger_pkg.all;

entity TEMP_SYS_TOP is
    port (
        CLK_FAST       : in  std_logic;
        CLK_SLOW       : in  std_logic;
        SYS_RST        : in  std_logic;
        
        DATA_STR       : in  std_logic;
        ADC_DATA8      : in  adc_data8_type;
        
        L0_PRE_TRIG    : out std_logic;
        CNN_OUT_DATA   : out std_logic_vector(31 downto 0);
        CNN_OUT_VALID  : out std_logic;
        CNN_OUT_READY  : in  std_logic
    );
end TEMP_SYS_TOP;

architecture rtl of TEMP_SYS_TOP is

    -- Hardcoded Temporary Configurations
    constant C_THRESH  : std_logic_vector(11 downto 0) := x"800";
    constant C_WINDOW  : std_logic_vector( 7 downto 0) := x"14"; -- 20 ticks
    constant C_BIN_THR : std_logic_vector( 3 downto 0) := x"2";  -- >= 2 channels

begin

    u_HILO_PATH : entity work.HILO_PATH_WRAPPER
        port map (
            CLK_FAST       => CLK_FAST,
            CLK_SLOW       => CLK_SLOW,
            SYS_RST        => SYS_RST,
            DATA_STR       => DATA_STR,
            ADC_DATA8      => ADC_DATA8,
            THRESH         => C_THRESH,
            WINDOW         => C_WINDOW,
            BIN_THR        => C_BIN_THR,
            L0_PRE_TRIG    => L0_PRE_TRIG,
            CNN_OUT_DATA   => CNN_OUT_DATA,
            CNN_OUT_VALID  => CNN_OUT_VALID,
            CNN_OUT_READY  => CNN_OUT_READY
        );

end rtl;