library ieee;
use ieee.std_logic_1164.all;

package vcomponents is
    component xpm_cdc_handshake
        generic (
            DEST_EXT_HSK   : integer := 1;
            DEST_SYNC_FF   : integer := 2;
            INIT_SYNC_FF   : integer := 0;
            SIM_ASSERT_CHK : integer := 0;
            SRC_SYNC_FF    : integer := 2;
            WIDTH          : integer := 1
        );
        port (
            src_clk  : in  std_logic;
            src_in   : in  std_logic_vector(WIDTH-1 downto 0);
            src_send : in  std_logic;
            src_rcv  : out std_logic;
            dest_clk : in  std_logic;
            dest_out : out std_logic_vector(WIDTH-1 downto 0);
            dest_req : out std_logic;
            dest_ack : in  std_logic
        );
    end component;
end package vcomponents;
