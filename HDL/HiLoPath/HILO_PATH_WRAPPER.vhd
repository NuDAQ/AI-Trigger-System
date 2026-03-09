library ieee;
use ieee.std_logic_1164.all;
use work.pre_trigger_pkg.all;

entity HILO_PATH_WRAPPER is
    port (
        CLK_FAST       : in  std_logic;
        CLK_SLOW       : in  std_logic;
        SYS_RST        : in  std_logic;
        
        DATA_STR       : in  std_logic;
        ADC_DATA8      : in  adc_data8_type;
        THRESH         : in  std_logic_vector(11 downto 0);
        WINDOW         : in  std_logic_vector( 7 downto 0);
        BIN_THR        : in  std_logic_vector( 3 downto 0);
        
        L0_PRE_TRIG    : out std_logic;
        CNN_OUT_DATA   : out std_logic_vector(31 downto 0);
        CNN_OUT_VALID  : out std_logic;
        CNN_OUT_READY  : in  std_logic
    );
end HILO_PATH_WRAPPER;

architecture structural of HILO_PATH_WRAPPER is

    component WRAPPER_TOP
        generic (
            INPUT_WIDTH   : integer := 64;
            OUTPUT_WIDTH  : integer := 32;
            NUM_TIMESTEPS : integer := 256;
            NUM_CHANNELS  : integer := 4
        );
        port (
            clk          : in  std_logic;
            rst_n        : in  std_logic;
            start        : in  std_logic;
            done         : out std_logic;
            idle         : out std_logic;
            ready        : out std_logic;
            input_data   : in  std_logic_vector(63 downto 0);
            input_valid  : in  std_logic;
            input_ready  : out std_logic;
            output_data  : out std_logic_vector(31 downto 0);
            output_valid : out std_logic;
            output_ready : in  std_logic
        );
    end component;

    signal sys_rst_n    : std_logic;
    signal pre_trig_int : std_logic;
    signal cnn_start    : std_logic;
    signal cnn_done     : std_logic;
    signal cnn_idle     : std_logic;
    signal cnn_ready    : std_logic;
    signal cnn_in_data  : std_logic_vector(63 downto 0);
    signal cnn_in_valid : std_logic;
    signal cnn_in_ready : std_logic;

begin

    sys_rst_n   <= not SYS_RST;
    L0_PRE_TRIG <= pre_trig_int;

    u_PRE_TRIGGER : entity work.PRE_TRIGGER
        port map (
            CLK       => CLK_FAST,
            RESET     => SYS_RST,
            DATA_STR  => DATA_STR,
            ADC_DATA8 => ADC_DATA8,
            THRESH    => THRESH,
            WINDOW    => WINDOW,
            BIN_THR   => BIN_THR,
            PRE_TRIG  => pre_trig_int
        );

    u_CONNECTOR : entity work.CNN_FIFO_CONNECTOR
        generic map ( C_CH0 => 0, C_CH1 => 1, C_CH2 => 2, C_CH3 => 3 )
        port map (
            CLK_FAST     => CLK_FAST,
            SYS_RST      => SYS_RST,
            DATA_STR     => DATA_STR,
            ADC_DATA8    => ADC_DATA8,
            L0_PRE_TRIG  => pre_trig_int,
            CLK_SLOW     => CLK_SLOW,
            CNN_START    => cnn_start,
            CNN_DONE     => cnn_done,
            CNN_IDLE     => cnn_idle,
            CNN_READY    => cnn_ready,
            CNN_IN_DATA  => cnn_in_data,
            CNN_IN_VALID => cnn_in_valid,
            CNN_IN_READY => cnn_in_ready
        );

    u_CNN_WRAPPER : WRAPPER_TOP
        port map (
            clk          => CLK_SLOW,
            rst_n        => sys_rst_n,
            start        => cnn_start,
            done         => cnn_done,
            idle         => cnn_idle,
            ready        => cnn_ready,
            input_data   => cnn_in_data,
            input_valid  => cnn_in_valid,
            input_ready  => cnn_in_ready,
            output_data  => CNN_OUT_DATA,
            output_valid => CNN_OUT_VALID,
            output_ready => CNN_OUT_READY
        );

end structural;