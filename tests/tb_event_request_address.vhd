library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_event_request_address is
end entity tb_event_request_address;

architecture sim of tb_event_request_address is
begin
    process
        variable anchor : logical_beat_t;
        variable result : logical_beat_t;
        variable request_value : event_request_t;
    begin
        anchor.chunk_id    := to_unsigned(7, CHUNK_ID_WIDTH);
        anchor.beat_offset := to_unsigned(40, BEAT_OFFSET_WIDTH);
        result := subtract_beats(anchor, 31);
        assert result.chunk_id = to_unsigned(7, CHUNK_ID_WIDTH) and
               result.beat_offset = to_unsigned(9, BEAT_OFFSET_WIDTH)
            report "same-chunk centered subtraction is wrong" severity failure;

        anchor.beat_offset := to_unsigned(10, BEAT_OFFSET_WIDTH);
        result := subtract_beats(anchor, 31);
        assert result.chunk_id = to_unsigned(6, CHUNK_ID_WIDTH) and
               result.beat_offset = to_unsigned(43, BEAT_OFFSET_WIDTH)
            report "centered subtraction must cross to the preceding chunk" severity failure;

        anchor.chunk_id    := (others => '0');
        anchor.beat_offset := (others => '0');
        result := subtract_beats(anchor, 31);
        assert result.chunk_id = to_unsigned(65535, CHUNK_ID_WIDTH) and
               result.beat_offset = to_unsigned(33, BEAT_OFFSET_WIDTH)
            report "logical beat subtraction must wrap the chunk identity" severity failure;

        anchor.chunk_id    := to_unsigned(65535, CHUNK_ID_WIDTH);
        anchor.beat_offset := to_unsigned(63, BEAT_OFFSET_WIDTH);
        result := add_beats(anchor, 1);
        assert result.chunk_id = to_unsigned(0, CHUNK_ID_WIDTH) and
               result.beat_offset = to_unsigned(0, BEAT_OFFSET_WIDTH)
            report "logical beat addition must wrap chunk and beat together" severity failure;

        request_value.start_address  := result;
        request_value.event_timestamp := to_unsigned(42, TIMESTAMP_WIDTH);
        request_value.trigger_offset := to_unsigned(17, BEAT_OFFSET_WIDTH);
        request_value.score          := x"12345678";
        assert request_value.trigger_offset = to_unsigned(17, BEAT_OFFSET_WIDTH)
            report "event request trigger offset is not retained" severity failure;

        report "tb_event_request_address passed";
        stop;
        wait;
    end process;
end architecture sim;
