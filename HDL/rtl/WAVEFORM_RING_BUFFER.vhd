library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.AI_TRIGGER_PKG.all;

entity WAVEFORM_RING_BUFFER is
    port (
        CLK             : in  std_logic;
        RST             : in  std_logic;

        DATA_STR        : in  std_logic;
        ADC_DATA4       : in  adc_data4_t;

        CHUNK_COMMIT    : out std_logic;
        COMMIT_CHUNK_ID : out chunk_id_t;

        RD_EN           : in  std_logic;
        RD_CHUNK_ID     : in  chunk_id_t;
        RD_BATCH_IDX    : in  integer range 0 to N_BATCHES - 1;
        RD_DATA         : out raw_adc_batch_t;
        RD_VALID        : out std_logic;
        RD_HIT          : out std_logic
    );
end entity WAVEFORM_RING_BUFFER;

architecture rtl of WAVEFORM_RING_BUFFER is
    type batch_mem_t is array (0 to WAVEFORM_RING_DEPTH * N_BATCHES - 1) of raw_adc_batch_t;
    type tag_mem_t is array (0 to WAVEFORM_RING_DEPTH - 1) of chunk_id_t;
    type valid_mem_t is array (0 to WAVEFORM_RING_DEPTH - 1) of std_logic;

    signal batch_mem : batch_mem_t := (others => (others => '0'));
    signal tag_mem   : tag_mem_t := (others => (others => '0'));
    signal valid_mem : valid_mem_t := (others => '0');

    signal batch_cnt  : integer range 0 to N_BATCHES - 1 := 0;
    signal chunk_id   : chunk_id_t := (others => '0');
    signal wr_slot    : integer range 0 to WAVEFORM_RING_DEPTH - 1 := 0;

    signal commit_r       : std_logic := '0';
    signal commit_chunk_r : chunk_id_t := (others => '0');
    signal rd_data_r      : raw_adc_batch_t := (others => '0');
    signal rd_valid_r     : std_logic := '0';
    signal rd_hit_r       : std_logic := '0';

    function pack_adc_batch(d : adc_data4_t) return raw_adc_batch_t is
        variable packed : raw_adc_batch_t := (others => '0');
    begin
        for ch in 0 to N_CH - 1 loop
            for s in 0 to N_BATCH_S - 1 loop
                packed((ch * N_BATCH_S + s) * 12 + 11 downto
                       (ch * N_BATCH_S + s) * 12) := d(ch)(s);
            end loop;
        end loop;
        return packed;
    end function;

    function ring_slot(id : chunk_id_t) return integer is
    begin
        return to_integer(id mod to_unsigned(WAVEFORM_RING_DEPTH, CHUNK_ID_WIDTH));
    end function;
begin
    process(CLK)
        variable rd_slot : integer range 0 to WAVEFORM_RING_DEPTH - 1;
        variable rd_addr : integer range 0 to WAVEFORM_RING_DEPTH * N_BATCHES - 1;
        variable wr_addr : integer range 0 to WAVEFORM_RING_DEPTH * N_BATCHES - 1;
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                batch_cnt      <= 0;
                chunk_id       <= (others => '0');
                wr_slot        <= 0;
                valid_mem      <= (others => '0');
                commit_r       <= '0';
                commit_chunk_r <= (others => '0');
                rd_valid_r     <= '0';
                rd_hit_r       <= '0';
                rd_data_r      <= (others => '0');
            else
                commit_r   <= '0';
                rd_valid_r <= '0';
                rd_hit_r   <= '0';

                if DATA_STR = '1' then
                    wr_addr := wr_slot * N_BATCHES + batch_cnt;
                    batch_mem(wr_addr) <= pack_adc_batch(ADC_DATA4);

                    if batch_cnt = N_BATCHES - 1 then
                        tag_mem(wr_slot)   <= chunk_id;
                        valid_mem(wr_slot) <= '1';
                        commit_r           <= '1';
                        commit_chunk_r     <= chunk_id;
                        chunk_id           <= chunk_id + 1;
                        batch_cnt          <= 0;
                        if wr_slot = WAVEFORM_RING_DEPTH - 1 then
                            wr_slot <= 0;
                        else
                            wr_slot <= wr_slot + 1;
                        end if;
                    else
                        batch_cnt <= batch_cnt + 1;
                    end if;
                end if;

                if RD_EN = '1' then
                    rd_slot := ring_slot(RD_CHUNK_ID);
                    rd_addr := rd_slot * N_BATCHES + RD_BATCH_IDX;
                    rd_data_r  <= batch_mem(rd_addr);
                    rd_valid_r <= '1';
                    if valid_mem(rd_slot) = '1' and tag_mem(rd_slot) = RD_CHUNK_ID then
                        rd_hit_r <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    CHUNK_COMMIT    <= commit_r;
    COMMIT_CHUNK_ID <= commit_chunk_r;
    RD_DATA         <= rd_data_r;
    RD_VALID        <= rd_valid_r;
    RD_HIT          <= rd_hit_r;
end architecture rtl;
