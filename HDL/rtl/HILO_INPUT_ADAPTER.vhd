library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity HILO_INPUT_ADAPTER is
    port (
        CLK               : in  std_logic;
        RST               : in  std_logic;
        MODE_START        : in  std_logic;
        ENABLE            : in  std_logic;
        DATA_STR          : in  std_logic;
        ADC_DATA4         : in  work.AI_TRIGGER_PKG.adc_data4_t;
        WRITE_CHUNK_ID    : in  chunk_id_t;
        WRITE_BEAT_OFFSET : in  beat_offset_t;
        WRITE_TIMESTAMP   : in  timestamp_t;

        HL_DATA_STR       : out std_logic;
        HL_ADC_DATA4      : out work.PRE_TRIGGER_pkg.adc_data4_type;
        HL_ANCHOR_CHUNK   : out chunk_id_t;
        HL_ANCHOR_OFFSET  : out beat_offset_t;
        HL_ANCHOR_TIME    : out timestamp_t;
        BUSY              : out std_logic
    );
end entity HILO_INPUT_ADAPTER;

architecture rtl of HILO_INPUT_ADAPTER is
    signal batch_r : work.PRE_TRIGGER_pkg.adc_data4_type :=
        (others => (others => (others => '0')));
    signal beat_count_r : integer range 0 to 3 := 0;
    signal hl_data_str_r : std_logic := '0';
    signal anchor_chunk_r : chunk_id_t := (others => '0');
    signal anchor_offset_r : beat_offset_t := (others => '0');
    signal anchor_time_r : timestamp_t := (others => '0');
begin
    process (CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' or MODE_START = '1' then
                batch_r         <= (others => (others => (others => '0')));
                beat_count_r    <= 0;
                hl_data_str_r   <= '0';
                anchor_chunk_r  <= (others => '0');
                anchor_offset_r <= (others => '0');
                anchor_time_r   <= (others => '0');
            else
                hl_data_str_r <= '0';
                if ENABLE = '1' and DATA_STR = '1' then
                    for ch in 0 to N_TRIGGER_CH - 1 loop
                        for sample_idx in 0 to N_BATCH_S - 1 loop
                            batch_r(ch)(beat_count_r * N_BATCH_S + sample_idx) <=
                                ADC_DATA4(ch)(sample_idx);
                        end loop;
                    end loop;

                    if beat_count_r = 3 then
                        beat_count_r    <= 0;
                        hl_data_str_r   <= '1';
                        anchor_chunk_r  <= WRITE_CHUNK_ID;
                        anchor_offset_r <= WRITE_BEAT_OFFSET;
                        anchor_time_r   <= WRITE_TIMESTAMP;
                    else
                        beat_count_r <= beat_count_r + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    HL_DATA_STR      <= hl_data_str_r;
    HL_ADC_DATA4     <= batch_r;
    HL_ANCHOR_CHUNK  <= anchor_chunk_r;
    HL_ANCHOR_OFFSET <= anchor_offset_r;
    HL_ANCHOR_TIME   <= anchor_time_r;
    BUSY <= '1' when beat_count_r /= 0 else '0';
end architecture rtl;
