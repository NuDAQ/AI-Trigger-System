library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity WRAPPER_TOP is
    generic (
        INPUT_WIDTH   : integer := 128;
        OUTPUT_WIDTH  : integer := 32;
        NUM_TIMESTEPS : integer := 256;
        NUM_CHANNELS  : integer := 4
    );
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        start        : in  std_logic;
        done         : out std_logic;
        idle         : out std_logic;
        ready        : out std_logic;
        input_data   : in  std_logic_vector(127 downto 0);
        input_valid  : in  std_logic;
        input_ready  : out std_logic;
        output_data  : out std_logic_vector(31 downto 0);
        output_valid : out std_logic;
        output_ready : in  std_logic
    );
end entity WRAPPER_TOP;

architecture sim of WRAPPER_TOP is
    signal input_count : integer range 0 to N_CHUNK_BEATS_CNN := 0;
begin
    input_ready <= '1';
    ready <= '0';
    idle <= '1' when input_count = 0 else '0';
    done <= output_valid;
    output_data <= std_logic_vector(to_signed(2048, 32));

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                input_count <= 0;
                output_valid <= '0';
            else
                if output_valid = '1' and output_ready = '1' then
                    output_valid <= '0';
                end if;

                if input_valid = '1' then
                    assert start = '1'
                        report "CNN_CORE_LANE must keep HLS start asserted while streaming payload"
                        severity failure;
                    if input_count = N_CHUNK_BEATS_CNN - 1 then
                        input_count <= 0;
                        output_valid <= '1';
                    else
                        input_count <= input_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture sim;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity tb_cnn_core_lane_start_protocol is
end entity tb_cnn_core_lane_start_protocol;

architecture sim of tb_cnn_core_lane_start_protocol is
    signal clk_adc         : std_logic := '0';
    signal clk_cnn         : std_logic := '0';
    signal rst             : std_logic := '1';
    signal rst_adc         : std_logic := '1';
    signal rst_cnn         : std_logic := '1';
    signal wr_en           : std_logic := '0';
    signal batch_data      : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0) := (others => '0');
    signal chunk_id        : chunk_id_t := (others => '0');
    signal chunk_timestamp : timestamp_t := (others => '0');
    signal work_start_offset : beat_offset_t := (others => '0');
    signal work_trigger_offset : beat_offset_t := (others => '0');
    signal cnn_thresh      : std_logic_vector(31 downto 0) := (others => '0');
    signal chunk_busy      : std_logic;
    signal lane_score      : std_logic_vector(31 downto 0);
    signal lane_chunk_id   : chunk_id_t;
    signal lane_timestamp  : timestamp_t;
    signal lane_start_offset : beat_offset_t;
    signal lane_trigger_offset : beat_offset_t;
    signal lane_thresh     : std_logic_vector(31 downto 0);
    signal lane_valid      : std_logic;
    signal lane_ready      : std_logic := '0';
begin
    clk_adc <= not clk_adc after 2 ns;
    clk_cnn <= not clk_cnn after 2 ns;

    u_dut : entity work.CNN_CORE_LANE
        port map (
            CLK_ADC         => clk_adc,
            CLK_CNN         => clk_cnn,
            RST_ASYNC       => rst,
            RST_ADC         => rst_adc,
            RST_CNN         => rst_cnn,
            WR_EN           => wr_en,
            BATCH_DATA      => batch_data,
            CHUNK_ID        => chunk_id,
            CHUNK_TIMESTAMP => chunk_timestamp,
            WORK_START_OFFSET => work_start_offset,
            WORK_TRIGGER_OFFSET => work_trigger_offset,
            CNN_THRESH      => cnn_thresh,
            CHUNK_BUSY      => chunk_busy,
            WORK_PENDING    => open,
            LANE_SCORE      => lane_score,
            LANE_CHUNK_ID   => lane_chunk_id,
            LANE_TIMESTAMP  => lane_timestamp,
            LANE_START_OFFSET => lane_start_offset,
            LANE_TRIGGER_OFFSET => lane_trigger_offset,
            LANE_THRESH     => lane_thresh,
            LANE_VALID      => lane_valid,
            LANE_READY      => lane_ready
        );

    process
    begin
        wait until rising_edge(clk_adc);
        rst <= '0';
        rst_adc <= '0';
        rst_cnn <= '0';
        chunk_id <= to_unsigned(12, CHUNK_ID_WIDTH);
        chunk_timestamp <= to_unsigned(34, TIMESTAMP_WIDTH);
        work_start_offset <= to_unsigned(45, BEAT_OFFSET_WIDTH);
        work_trigger_offset <= to_unsigned(9, BEAT_OFFSET_WIDTH);
        cnn_thresh <= x"00000123";

        for i in 0 to N_BATCHES - 1 loop
            wr_en <= '1';
            batch_data <= std_logic_vector(to_unsigned(i, LANE_FIFO_WRITE_WIDTH));
            wait until rising_edge(clk_adc);
        end loop;
        wr_en <= '0';

        for i in 0 to 400 loop
            wait until rising_edge(clk_cnn);
            if lane_valid = '1' then
                assert lane_chunk_id = to_unsigned(12, CHUNK_ID_WIDTH)
                    report "lane output chunk id mismatch"
                    severity failure;
                assert lane_timestamp = to_unsigned(34, TIMESTAMP_WIDTH) and
                       lane_start_offset = to_unsigned(45, BEAT_OFFSET_WIDTH) and
                       lane_trigger_offset = to_unsigned(9, BEAT_OFFSET_WIDTH) and
                       lane_thresh = x"00000123"
                    report "lane result metadata mismatch" severity failure;
                for hold_cycle in 0 to 2 loop
                    wait until rising_edge(clk_cnn);
                    wait for 1 ps;
                    assert lane_valid = '1' and
                           lane_chunk_id = to_unsigned(12, CHUNK_ID_WIDTH) and
                           lane_start_offset = to_unsigned(45, BEAT_OFFSET_WIDTH)
                        report "lane result changed while backpressured" severity failure;
                end loop;
                lane_ready <= '1';
                wait until rising_edge(clk_cnn);
                lane_ready <= '0';
                wait until rising_edge(clk_cnn);
                wait for 1 ps;
                assert lane_valid = '0'
                    report "lane result did not retire after ready/valid handshake" severity failure;
                report "tb_cnn_core_lane_start_protocol passed";
                stop;
            end if;
        end loop;

        assert false
            report "timed out waiting for lane output"
            severity failure;
    end process;
end architecture sim;
