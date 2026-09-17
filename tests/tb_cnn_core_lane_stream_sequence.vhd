library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.AI_TRIGGER_PKG.all;

entity WRAPPER_TOP is
    generic (
        INPUT_WIDTH   : integer := 512;
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
        input_data   : in  std_logic_vector(511 downto 0);
        input_valid  : in  std_logic;
        input_ready  : out std_logic;
        output_data  : out std_logic_vector(31 downto 0);
        output_valid : out std_logic;
        output_ready : in  std_logic
    );
end entity WRAPPER_TOP;

architecture sim of WRAPPER_TOP is
    signal input_count : integer range 0 to 32 := 0;
begin
    input_ready <= '1';
    ready <= '1' when input_count = 32 else '0';
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
                output_valid <= '0';

                if input_valid = '1' and input_ready = '1' then
                    assert input_count < 32 report "extra native input beat" severity failure;
                    assert unsigned(input_data(255 downto 0)) = 2 * input_count and
                           unsigned(input_data(511 downto 256)) = 2 * input_count + 1
                        report "native word lost ADC chronology or consumed an empty FIFO" severity failure;

                    if input_count = 31 then
                        input_count <= 32;
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

entity tb_cnn_core_lane_stream_sequence is
end entity tb_cnn_core_lane_stream_sequence;

architecture sim of tb_cnn_core_lane_stream_sequence is
    signal clk_adc         : std_logic := '0';
    signal clk_cnn         : std_logic := '0';
    signal rst             : std_logic := '1';
    signal rst_adc         : std_logic := '1';
    signal rst_cnn         : std_logic := '1';
    signal wr_en           : std_logic := '0';
    signal batch_data      : std_logic_vector(LANE_FIFO_WRITE_WIDTH - 1 downto 0) := (others => '0');
    signal chunk_id        : chunk_id_t := (others => '0');
    signal chunk_timestamp : timestamp_t := (others => '0');
    signal cnn_thresh      : std_logic_vector(31 downto 0) := (others => '0');
    signal chunk_busy      : std_logic;
    signal lane_score      : std_logic_vector(31 downto 0);
    signal lane_chunk_id   : chunk_id_t;
    signal lane_timestamp  : timestamp_t;
    signal lane_thresh     : std_logic_vector(31 downto 0);
    signal lane_valid      : std_logic;
begin
    clk_adc <= not clk_adc after 2 ns;
    clk_cnn <= not clk_cnn after 2.5 ns;

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
            WORK_START_OFFSET => (others => '0'),
            WORK_TRIGGER_OFFSET => (others => '0'),
            CNN_THRESH      => cnn_thresh,
            CHUNK_BUSY      => chunk_busy,
            WORK_PENDING    => open,
            LANE_SCORE      => lane_score,
            LANE_CHUNK_ID   => lane_chunk_id,
            LANE_TIMESTAMP  => lane_timestamp,
            LANE_START_OFFSET => open,
            LANE_TRIGGER_OFFSET => open,
            LANE_THRESH     => lane_thresh,
            LANE_VALID      => lane_valid,
            LANE_READY      => '1'
        );

    process
    begin
        wait until rising_edge(clk_adc);
        rst <= '0';
        rst_adc <= '0';
        rst_cnn <= '0';

        for i in 0 to N_BATCHES - 1 loop
            wr_en <= '1';
            batch_data <= std_logic_vector(to_unsigned(i, batch_data'length));
            wait until rising_edge(clk_adc);
            wr_en <= '0';
            -- Empty periods are much longer than both CDC and the read clock.
            if i < N_BATCHES - 1 then
            for gap in 0 to 8 loop
                wait until rising_edge(clk_adc);
            end loop;
            end if;
        end loop;
        wr_en <= '0';

        for i in 0 to 500 loop
            wait until rising_edge(clk_cnn);
            if lane_valid = '1' then
                report "tb_cnn_core_lane_stream_sequence passed";
                stop;
            end if;
        end loop;

        assert false
            report "timed out waiting for lane output"
            severity failure;
    end process;
end architecture sim;
