library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TRIGGER_MODE_CTRL is
    port (
        CLK                 : in  std_logic;
        RST                 : in  std_logic;
        REQUESTED_MODE      : in  std_logic_vector(3 downto 0);
        CHUNK_BOUNDARY      : in  std_logic;
        PATH_IDLE           : in  std_logic;

        ACTIVE_MODE         : out std_logic_vector(3 downto 0);
        MODE_SWITCH_PENDING : out std_logic;
        INVALID_REQUEST     : out std_logic;
        ACCEPT_NEW_WORK     : out std_logic;
        MODE_START          : out std_logic
    );
end entity TRIGGER_MODE_CTRL;

architecture rtl of TRIGGER_MODE_CTRL is
    type state_t is (RESET_HOLD, RUNNING, DRAINING, WAIT_BOUNDARY);

    signal state_r       : state_t := RESET_HOLD;
    signal active_mode_r : std_logic_vector(3 downto 0) := "1111";
    signal mode_start_r  : std_logic := '0';

    function is_valid_mode(mode_value : std_logic_vector(3 downto 0))
        return boolean is
    begin
        return unsigned(mode_value) <= to_unsigned(4, mode_value'length);
    end function;
begin
    process (CLK)
    begin
        if rising_edge(CLK) then
            mode_start_r <= '0';

            if RST = '1' then
                state_r       <= RESET_HOLD;
                active_mode_r <= "1111";
            else
                case state_r is
                    when RESET_HOLD =>
                        if CHUNK_BOUNDARY = '1' and PATH_IDLE = '1' then
                            active_mode_r <= REQUESTED_MODE;
                            state_r       <= RUNNING;
                            mode_start_r  <= '1';
                        end if;

                    when RUNNING =>
                        if REQUESTED_MODE /= active_mode_r and
                           CHUNK_BOUNDARY = '1' then
                            if PATH_IDLE = '1' then
                                active_mode_r <= REQUESTED_MODE;
                                state_r       <= RUNNING;
                                mode_start_r  <= '1';
                            else
                                state_r <= DRAINING;
                            end if;
                        end if;

                    when DRAINING =>
                        if PATH_IDLE = '1' then
                            state_r <= WAIT_BOUNDARY;
                        end if;

                    when WAIT_BOUNDARY =>
                        if REQUESTED_MODE /= active_mode_r and
                           PATH_IDLE = '0' then
                            state_r <= DRAINING;
                        elsif CHUNK_BOUNDARY = '1' then
                            active_mode_r <= REQUESTED_MODE;
                            state_r       <= RUNNING;
                            mode_start_r  <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process;

    ACTIVE_MODE <= active_mode_r;
    MODE_START  <= mode_start_r;

    INVALID_REQUEST <= '0' when is_valid_mode(REQUESTED_MODE) else '1';
    MODE_SWITCH_PENDING <= '1' when state_r = RESET_HOLD or
                                   REQUESTED_MODE /= active_mode_r else '0';
    ACCEPT_NEW_WORK <= '1' when state_r = RUNNING and
                                is_valid_mode(active_mode_r) else '0';
end architecture rtl;
