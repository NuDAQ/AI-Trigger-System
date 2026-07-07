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
    signal start_seen_in_txn : std_logic := '0';
begin
    input_ready <= '1';
    ready <= '1';
    idle <= '1' when input_count = 0 else '0';
    done <= output_valid;
    output_data <= std_logic_vector(to_signed(2048, 32));

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                input_count <= 0;
                output_valid <= '0';
                start_seen_in_txn <= '0';
            else
                output_valid <= '0';

                if start = '1' then
                    assert start_seen_in_txn = '0'
                        report "CNN_CORE_LANE must not hold HLS start high after the transaction request"
                        severity failure;
                    start_seen_in_txn <= '1';
                end if;

                if input_valid = '1' then
                    if input_count = N_CHUNK_BEATS_CNN - 1 then
                        input_count <= 0;
                        start_seen_in_txn <= '0';
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
    signal cnn_thresh      : std_logic_vector(31 downto 0) := (others => '0');
    signal chunk_busy      : std_logic;
    signal lane_score      : std_logic_vector(31 downto 0);
    signal lane_chunk_id   : chunk_id_t;
    signal lane_timestamp  : timestamp_t;
    signal lane_thresh     : std_logic_vector(31 downto 0);
    signal lane_valid      : std_logic;
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
            CNN_THRESH      => cnn_thresh,
            CHUNK_BUSY      => chunk_busy,
            LANE_SCORE      => lane_score,
            LANE_CHUNK_ID   => lane_chunk_id,
            LANE_TIMESTAMP  => lane_timestamp,
            LANE_THRESH     => lane_thresh,
            LANE_VALID      => lane_valid
        );

    process
    begin
        wait until rising_edge(clk_adc);
        rst <= '0';
        rst_adc <= '0';
        rst_cnn <= '0';

        for i in 0 to N_BATCHES - 1 loop
            wr_en <= '1';
            batch_data <= std_logic_vector(to_unsigned(i, LANE_FIFO_WRITE_WIDTH));
            wait until rising_edge(clk_adc);
        end loop;
        wr_en <= '0';

        for i in 0 to 400 loop
            wait until rising_edge(clk_cnn);
            if lane_valid = '1' then
                assert lane_chunk_id = to_unsigned(0, CHUNK_ID_WIDTH)
                    report "lane output chunk id mismatch"
                    severity failure;
                report "tb_cnn_core_lane_start_protocol passed";
                stop;
            end if;
        end loop;

        assert false
            report "timed out waiting for lane output"
            severity failure;
    end process;
end architecture sim;
