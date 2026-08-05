library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity RING_READ_ARBITER is
    port (
        CLK                    : in  std_logic;
        RST                    : in  std_logic;

        EVENT_CHECK_VALID      : in  std_logic;
        EVENT_CHECK_CHUNK      : in  chunk_id_t;
        EVENT_CHECK_OFFSET     : in  beat_offset_t;
        EVENT_CHECK_PRESENT    : out std_logic;
        EVENT_CHECK_PROTECTED  : out std_logic;
        EVENT_CHECK_EXPIRED    : out std_logic;
        GATED_CHECK_VALID      : in  std_logic;
        GATED_CHECK_CHUNK      : in  chunk_id_t;
        GATED_CHECK_OFFSET     : in  beat_offset_t;
        GATED_CHECK_PRESENT    : out std_logic;
        GATED_CHECK_PROTECTED  : out std_logic;
        GATED_CHECK_EXPIRED    : out std_logic;
        SHARED_CHECK_CHUNK     : out chunk_id_t;
        SHARED_CHECK_OFFSET    : out beat_offset_t;
        SHARED_CHECK_PRESENT   : in  std_logic;
        SHARED_CHECK_PROTECTED : in  std_logic;
        SHARED_CHECK_EXPIRED   : in  std_logic;

        EVENT_REQUEST          : in  std_logic;
        EVENT_GRANT            : out std_logic;
        EVENT_DONE             : in  std_logic;
        EVENT_CONTINUE         : in  std_logic;
        EVENT_OWNER_ACTIVE     : in  std_logic;
        GATED_REQUEST          : in  std_logic;
        GATED_GRANT            : out std_logic;
        GATED_DONE             : in  std_logic;

        EVENT_RD_EN            : in  std_logic;
        EVENT_RD_CHUNK         : in  chunk_id_t;
        EVENT_RD_IDX           : in  integer range 0 to N_BATCHES - 1;
        EVENT_RD_VALID         : out std_logic;
        EVENT_RD_HIT           : out std_logic;
        GATED_RD_EN            : in  std_logic;
        GATED_RD_CHUNK         : in  chunk_id_t;
        GATED_RD_IDX           : in  integer range 0 to N_BATCHES - 1;
        GATED_RD_VALID         : out std_logic;
        GATED_RD_HIT           : out std_logic;
        SHARED_RD_EN           : out std_logic;
        SHARED_RD_CHUNK        : out chunk_id_t;
        SHARED_RD_IDX          : out integer range 0 to N_BATCHES - 1;
        SHARED_RD_DATA         : in  raw_adc_batch_t;
        SHARED_RD_VALID        : in  std_logic;
        SHARED_RD_HIT          : in  std_logic
    );
end entity RING_READ_ARBITER;

architecture rtl of RING_READ_ARBITER is
    type owner_t is (OWNER_IDLE, OWNER_EVENT, OWNER_GATED);
    signal owner_r : owner_t := OWNER_IDLE;
begin
    process (CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                owner_r <= OWNER_IDLE;
            else
                case owner_r is
                    when OWNER_IDLE =>
                        if EVENT_REQUEST = '1' then
                            owner_r <= OWNER_EVENT;
                        elsif GATED_REQUEST = '1' then
                            owner_r <= OWNER_GATED;
                        end if;

                    when OWNER_EVENT =>
                        if EVENT_DONE = '1' then
                            if EVENT_CONTINUE = '1' or EVENT_CHECK_VALID = '1' or
                               EVENT_REQUEST = '1' then
                                owner_r <= OWNER_EVENT;
                            else
                                owner_r <= OWNER_IDLE;
                            end if;
                        elsif EVENT_OWNER_ACTIVE = '0' and EVENT_REQUEST = '0' and
                              EVENT_CHECK_VALID = '0' then
                            owner_r <= OWNER_IDLE;
                        end if;

                    when OWNER_GATED =>
                        if GATED_DONE = '1' then
                            owner_r <= OWNER_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    EVENT_GRANT <= '1' when owner_r = OWNER_EVENT or
        (owner_r = OWNER_IDLE and EVENT_REQUEST = '1') else '0';
    GATED_GRANT <= '1' when owner_r = OWNER_GATED or
        (owner_r = OWNER_IDLE and EVENT_REQUEST = '0' and
         GATED_REQUEST = '1') else '0';

    SHARED_CHECK_CHUNK <= EVENT_CHECK_CHUNK when EVENT_CHECK_VALID = '1'
        else GATED_CHECK_CHUNK;
    SHARED_CHECK_OFFSET <= EVENT_CHECK_OFFSET when EVENT_CHECK_VALID = '1'
        else GATED_CHECK_OFFSET;
    EVENT_CHECK_PRESENT <= SHARED_CHECK_PRESENT when EVENT_CHECK_VALID = '1' else '0';
    EVENT_CHECK_PROTECTED <= SHARED_CHECK_PROTECTED when EVENT_CHECK_VALID = '1' else '0';
    EVENT_CHECK_EXPIRED <= SHARED_CHECK_EXPIRED when EVENT_CHECK_VALID = '1' else '0';
    GATED_CHECK_PRESENT <= SHARED_CHECK_PRESENT when EVENT_CHECK_VALID = '0' and
        GATED_CHECK_VALID = '1' else '0';
    GATED_CHECK_PROTECTED <= SHARED_CHECK_PROTECTED when EVENT_CHECK_VALID = '0' and
        GATED_CHECK_VALID = '1' else '0';
    GATED_CHECK_EXPIRED <= SHARED_CHECK_EXPIRED when EVENT_CHECK_VALID = '0' and
        GATED_CHECK_VALID = '1' else '0';

    SHARED_RD_EN <= EVENT_RD_EN when owner_r = OWNER_EVENT else
                    GATED_RD_EN when owner_r = OWNER_GATED else '0';
    SHARED_RD_CHUNK <= EVENT_RD_CHUNK when owner_r = OWNER_EVENT else
                       GATED_RD_CHUNK;
    SHARED_RD_IDX <= EVENT_RD_IDX when owner_r = OWNER_EVENT else GATED_RD_IDX;

    EVENT_RD_VALID <= SHARED_RD_VALID when owner_r = OWNER_EVENT else '0';
    EVENT_RD_HIT   <= SHARED_RD_HIT when owner_r = OWNER_EVENT else '0';
    GATED_RD_VALID <= SHARED_RD_VALID when owner_r = OWNER_GATED else '0';
    GATED_RD_HIT   <= SHARED_RD_HIT when owner_r = OWNER_GATED else '0';
end architecture rtl;
