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

library ieee;
use ieee.std_logic_1164.all;

entity xpm_cdc_handshake is
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
end entity xpm_cdc_handshake;

architecture sim of xpm_cdc_handshake is
    constant DEST_REQ_HOLD_AFTER_ACK : integer := 4;
    signal src_payload      : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
    signal req_toggle_src   : std_logic := '0';
    signal ack_toggle_dest  : std_logic := '0';
    signal ack_sync_src     : std_logic_vector(1 downto 0) := (others => '0');
    signal req_sync_dest    : std_logic_vector(1 downto 0) := (others => '0');
    signal dest_req_r       : std_logic := '0';
    signal dest_out_r       : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
    signal dest_drop_count  : integer range 0 to DEST_REQ_HOLD_AFTER_ACK := 0;
    signal dest_ack_seen    : std_logic := '0';
begin
    process(src_clk)
    begin
        if rising_edge(src_clk) then
            ack_sync_src <= ack_sync_src(0) & ack_toggle_dest;
            if src_send = '1' and req_toggle_src = ack_sync_src(1) then
                src_payload    <= src_in;
                req_toggle_src <= not req_toggle_src;
            end if;
        end if;
    end process;

    process(dest_clk)
    begin
        if rising_edge(dest_clk) then
            req_sync_dest <= req_sync_dest(0) & req_toggle_src;

            if dest_req_r = '0' and req_sync_dest(1) /= ack_toggle_dest then
                dest_out_r <= src_payload;
                dest_drop_count <= 0;
                dest_ack_seen <= '0';
                if DEST_EXT_HSK = 0 then
                    ack_toggle_dest <= req_sync_dest(1);
                    dest_req_r      <= '1';
                else
                    dest_req_r      <= '1';
                end if;
            elsif dest_req_r = '1' then
                if DEST_EXT_HSK = 0 then
                    dest_req_r <= '0';
                elsif dest_ack_seen = '1' then
                    if dest_drop_count = DEST_REQ_HOLD_AFTER_ACK then
                        dest_req_r <= '0';
                        dest_drop_count <= 0;
                        dest_ack_seen <= '0';
                    else
                        dest_drop_count <= dest_drop_count + 1;
                    end if;
                elsif dest_ack = '1' then
                    ack_toggle_dest <= req_sync_dest(1);
                    dest_drop_count <= 0;
                    dest_ack_seen <= '1';
                end if;
            end if;
        end if;
    end process;

    src_rcv  <= src_send when req_toggle_src = ack_sync_src(1) else '0';
    dest_req <= dest_req_r;
    dest_out <= dest_out_r;
end architecture sim;
