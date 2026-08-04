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
        COMMIT_TIMESTAMP : out timestamp_t;

        WRITE_CHUNK_ID    : out chunk_id_t;
        WRITE_BEAT_OFFSET : out beat_offset_t;
        WRITE_TIMESTAMP   : out timestamp_t;

        CHECK_START_CHUNK_ID : in  chunk_id_t;
        CHECK_START_OFFSET   : in  beat_offset_t;
        CHECK_PRESENT        : out std_logic;
        CHECK_PROTECTED      : out std_logic;
        CHECK_EXPIRED        : out std_logic;

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
    signal chunk_timestamp : timestamp_t := (others => '0');
    signal wr_slot    : integer range 0 to WAVEFORM_RING_DEPTH - 1 := 0;

    signal commit_r       : std_logic := '0';
    signal commit_chunk_r : chunk_id_t := (others => '0');
    signal commit_timestamp_r : timestamp_t := (others => '0');
    signal have_commit_r  : std_logic := '0';
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
        return to_integer(unsigned(to_01(std_logic_vector(id), '0'))) mod
               WAVEFORM_RING_DEPTH;
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
                chunk_timestamp <= (others => '0');
                wr_slot        <= 0;
                valid_mem      <= (others => '0');
                commit_r       <= '0';
                commit_chunk_r <= (others => '0');
                commit_timestamp_r <= (others => '0');
                have_commit_r  <= '0';
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

                    if batch_cnt = 0 then
                        valid_mem(wr_slot) <= '0';
                    end if;

                    if batch_cnt = N_BATCHES - 1 then
                        tag_mem(wr_slot)   <= chunk_id;
                        valid_mem(wr_slot) <= '1';
                        commit_r           <= '1';
                        commit_chunk_r     <= chunk_id;
                        commit_timestamp_r <= chunk_timestamp;
                        have_commit_r      <= '1';
                        chunk_id           <= chunk_id + 1;
                        chunk_timestamp    <= chunk_timestamp + 1;
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

    process (
        valid_mem,
        tag_mem,
        CHECK_START_CHUNK_ID,
        CHECK_START_OFFSET,
        have_commit_r,
        commit_chunk_r
    )
        variable start_address : logical_beat_t;
        variable end_address   : logical_beat_t;
        variable start_slot    : integer range 0 to WAVEFORM_RING_DEPTH - 1;
        variable end_slot      : integer range 0 to WAVEFORM_RING_DEPTH - 1;
        variable age           : unsigned(CHUNK_ID_WIDTH - 1 downto 0);
        variable range_present : boolean;
    begin
        start_address.chunk_id    := CHECK_START_CHUNK_ID;
        start_address.beat_offset := CHECK_START_OFFSET;
        end_address := add_beats(start_address, N_BATCHES - 1);
        start_slot := ring_slot(start_address.chunk_id);
        end_slot   := ring_slot(end_address.chunk_id);

        range_present :=
            valid_mem(start_slot) = '1' and
            tag_mem(start_slot) = start_address.chunk_id and
            valid_mem(end_slot) = '1' and
            tag_mem(end_slot) = end_address.chunk_id;

        CHECK_PRESENT   <= '0';
        CHECK_PROTECTED <= '0';
        CHECK_EXPIRED   <= '0';

        age := commit_chunk_r - start_address.chunk_id;
        if range_present then
            CHECK_PRESENT <= '1';
            if have_commit_r = '1' and
               age <= to_unsigned(WAVEFORM_RING_DEPTH - 2, CHUNK_ID_WIDTH) then
                CHECK_PROTECTED <= '1';
            else
                CHECK_EXPIRED <= '1';
            end if;
        elsif have_commit_r = '1' and age(CHUNK_ID_WIDTH - 1) = '0' and
              age >= to_unsigned(WAVEFORM_RING_DEPTH - 1, CHUNK_ID_WIDTH) then
            CHECK_EXPIRED <= '1';
        end if;
    end process;

    CHUNK_COMMIT    <= commit_r;
    COMMIT_CHUNK_ID <= commit_chunk_r;
    COMMIT_TIMESTAMP <= commit_timestamp_r;
    WRITE_CHUNK_ID    <= chunk_id;
    WRITE_BEAT_OFFSET <= to_unsigned(batch_cnt, BEAT_OFFSET_WIDTH);
    WRITE_TIMESTAMP   <= chunk_timestamp;
    RD_DATA         <= rd_data_r;
    RD_VALID        <= rd_valid_r;
    RD_HIT          <= rd_hit_r;
end architecture rtl;
