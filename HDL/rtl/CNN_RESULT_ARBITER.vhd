library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity CNN_RESULT_ARBITER is
    port (
        CLK                 : in  std_logic;
        RST                 : in  std_logic;
        LANE_VALID          : in  std_logic_vector(N_LANES - 1 downto 0);
        LANE_READY          : out std_logic_vector(N_LANES - 1 downto 0);
        LANE_SCORE          : in  score_arr_t;
        LANE_THRESH         : in  score_arr_t;
        LANE_START_CHUNK    : in  chunk_id_arr_t;
        LANE_START_OFFSET   : in  beat_offset_arr_t;
        LANE_TIMESTAMP      : in  timestamp_arr_t;
        LANE_TRIGGER_OFFSET : in  beat_offset_arr_t;

        RESULT_VALID        : out std_logic;
        RESULT_QUALIFY      : out std_logic;
        RESULT_READY        : in  std_logic;
        RESULT_REQUEST      : out event_request_t;
        BUSY                : out std_logic
    );
end entity CNN_RESULT_ARBITER;

architecture rtl of CNN_RESULT_ARBITER is
    signal priority_r    : integer range 0 to N_LANES - 1 := 0;
    signal selected_s    : integer range -1 to N_LANES - 1 := -1;
    signal consume_s     : std_logic := '0';
begin
    process (
        LANE_VALID,
        LANE_SCORE,
        LANE_THRESH,
        LANE_START_CHUNK,
        LANE_START_OFFSET,
        LANE_TIMESTAMP,
        LANE_TRIGGER_OFFSET,
        RESULT_READY,
        priority_r
    )
        variable selected_v : integer range -1 to N_LANES - 1;
        variable lane_idx   : integer range 0 to N_LANES - 1;
        variable qualifying : boolean;
        variable ready_v    : std_logic_vector(N_LANES - 1 downto 0);
        variable request_v  : event_request_t;
        variable result_valid_v : std_logic;
        variable result_qualify_v : std_logic;
        variable consume_v  : std_logic;
    begin
        selected_v := -1;
        for offset in 0 to N_LANES - 1 loop
            lane_idx := (priority_r + offset) mod N_LANES;
            if selected_v = -1 and LANE_VALID(lane_idx) = '1' then
                selected_v := lane_idx;
            end if;
        end loop;

        ready_v       := (others => '0');
        request_v     := NULL_EVENT_REQUEST;
        result_valid_v := '0';
        result_qualify_v := '0';
        consume_v     := '0';

        if selected_v >= 0 then
            qualifying :=
                signed(LANE_SCORE(selected_v)(21 downto 0)) >
                signed(LANE_THRESH(selected_v)(21 downto 0));
            request_v.start_address.chunk_id := LANE_START_CHUNK(selected_v);
            request_v.start_address.beat_offset := LANE_START_OFFSET(selected_v);
            request_v.event_timestamp := LANE_TIMESTAMP(selected_v);
            request_v.trigger_offset := LANE_TRIGGER_OFFSET(selected_v);
            request_v.score := LANE_SCORE(selected_v);
            result_valid_v := '1';

            if qualifying then
                result_qualify_v := '1';
                ready_v(selected_v) := RESULT_READY;
                consume_v := RESULT_READY;
            else
                ready_v(selected_v) := '1';
                consume_v := '1';
            end if;
        end if;

        selected_s     <= selected_v;
        consume_s      <= consume_v;
        LANE_READY     <= ready_v;
        RESULT_VALID   <= result_valid_v;
        RESULT_QUALIFY <= result_qualify_v;
        RESULT_REQUEST <= request_v;
    end process;

    process (CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                priority_r <= 0;
            elsif selected_s >= 0 and consume_s = '1' then
                if selected_s = N_LANES - 1 then
                    priority_r <= 0;
                else
                    priority_r <= selected_s + 1;
                end if;
            end if;
        end if;
    end process;

    BUSY <= '0' when LANE_VALID = (LANE_VALID'range => '0') else '1';
end architecture rtl;
