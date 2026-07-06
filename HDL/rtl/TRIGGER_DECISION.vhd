library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity TRIGGER_DECISION is
    port (
        CLK              : in  std_logic;
        RST              : in  std_logic;

        SCORE_VALID      : in  std_logic;
        SCORE_DATA       : in  std_logic_vector(31 downto 0);
        SCORE_CHUNK_ID   : in  chunk_id_t;
        SCORE_TIMESTAMP  : in  timestamp_t;
        CNN_THRESH       : in  std_logic_vector(31 downto 0);

        TRIGGER_VALID    : out std_logic;
        TRIGGER_SCORE    : out std_logic_vector(31 downto 0);
        TRIGGER_CHUNK_ID : out chunk_id_t;
        TRIGGER_TIMESTAMP : out timestamp_t
    );
end entity TRIGGER_DECISION;

architecture rtl of TRIGGER_DECISION is
    signal trigger_valid_r    : std_logic := '0';
    signal trigger_score_r    : std_logic_vector(31 downto 0) := (others => '0');
    signal trigger_chunk_id_r : chunk_id_t := (others => '0');
    signal trigger_timestamp_r : timestamp_t := (others => '0');
begin
    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                trigger_valid_r    <= '0';
                trigger_score_r    <= (others => '0');
                trigger_chunk_id_r <= (others => '0');
                trigger_timestamp_r <= (others => '0');
            else
                trigger_valid_r <= '0';
                if SCORE_VALID = '1' and
                   signed(SCORE_DATA(21 downto 0)) > signed(CNN_THRESH(21 downto 0)) then
                    trigger_valid_r    <= '1';
                    trigger_score_r    <= SCORE_DATA;
                    trigger_chunk_id_r <= SCORE_CHUNK_ID;
                    trigger_timestamp_r <= SCORE_TIMESTAMP;
                end if;
            end if;
        end if;
    end process;

TRIGGER_VALID    <= trigger_valid_r;
TRIGGER_SCORE    <= trigger_score_r;
TRIGGER_CHUNK_ID <= trigger_chunk_id_r;
TRIGGER_TIMESTAMP <= trigger_timestamp_r;
end architecture rtl;
