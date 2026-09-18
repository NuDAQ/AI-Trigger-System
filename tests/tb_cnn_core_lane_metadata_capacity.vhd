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
    signal input_count : integer range 0 to 31 := 0;
    signal produced : natural := 0;
    signal consumed : natural := 0;
begin
    input_ready <= '1';
    ready <= '1' when input_valid = '1' and input_count = 31 else '0';
    idle <= '1' when input_count = 0 else '0';
    done <= ready;
    output_data <= std_logic_vector(to_unsigned(consumed, 32));
    output_valid <= '1' when produced /= consumed else '0';
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                input_count <= 0;
                produced <= 0;
                consumed <= 0;
            else
                if input_valid = '1' then
                    if input_count = 31 then
                        assert start = '1' report "missing native start request" severity failure;
                        input_count <= 0;
                        produced <= produced + 1;
                    else
                        input_count <= input_count + 1;
                    end if;
                end if;
                if output_valid = '1' and output_ready = '1' then
                    consumed <= consumed + 1;
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

entity tb_cnn_core_lane_metadata_capacity is
end entity tb_cnn_core_lane_metadata_capacity;

architecture sim of tb_cnn_core_lane_metadata_capacity is
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
    signal work_pending : std_logic;
    signal received : natural := 0;
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
            WORK_START_OFFSET => work_start_offset,
            WORK_TRIGGER_OFFSET => work_trigger_offset,
            CNN_THRESH      => cnn_thresh,
            CHUNK_BUSY      => chunk_busy,
            WORK_PENDING    => work_pending,
            LANE_SCORE      => lane_score,
            LANE_CHUNK_ID   => lane_chunk_id,
            LANE_TIMESTAMP  => lane_timestamp,
            LANE_START_OFFSET => lane_start_offset,
            LANE_TRIGGER_OFFSET => lane_trigger_offset,
            LANE_THRESH     => lane_thresh,
            LANE_VALID      => lane_valid,
            LANE_READY      => lane_ready
        );

    result_monitor : process(clk_cnn)
    begin
        if rising_edge(clk_cnn) then
            if rst = '1' then
                received <= 0;
            elsif lane_valid = '1' and lane_ready = '1' then
                assert to_integer(lane_chunk_id) = received and
                       to_integer(lane_timestamp) = 100 + received and
                       to_integer(unsigned(lane_thresh)) = 500 + received and
                       to_integer(unsigned(lane_score)) = received
                    report "metadata overwritten, reordered or threshold resampled" severity failure;
                received <= received + 1;
            end if;
        end if;
    end process;

    process
        procedure send_window(index_value : natural) is
        begin
            loop
                wait until falling_edge(clk_adc);
                exit when chunk_busy = '0';
            end loop;
            chunk_id <= to_unsigned(index_value, CHUNK_ID_WIDTH);
            chunk_timestamp <= to_unsigned(100 + index_value, TIMESTAMP_WIDTH);
            cnn_thresh <= std_logic_vector(to_unsigned(500 + index_value, 32));
            for beat in 0 to 63 loop
                wr_en <= '1';
                wait until falling_edge(clk_adc);
                -- Only the first beat's threshold belongs to this work item.
                cnn_thresh <= x"000FFFFF";
            end loop;
            wr_en <= '0';
        end procedure;
    begin
        wait for 20 ns;
        assert chunk_busy = '1' report "lane advertised acquisition capacity during reset" severity failure;
        wait for 20 ns;
        wait until falling_edge(clk_adc);
        rst <= '0'; rst_adc <= '0'; rst_cnn <= '0';
        -- 16 outstanding results must not make WORK_PENDING appear empty.
        for frame in 0 to 15 loop
            send_window(frame);
        end loop;
        wait for 100 ns;
        assert work_pending = '1'
            report "metadata counter wrapped and hid outstanding work" severity failure;
        -- One further complete acquisition may wait in the lane's input FIFO,
        -- but cannot overwrite any of the 16 reserved metadata entries.
        send_window(16);
        wait for 200 ns;
        assert chunk_busy = '1' and work_pending = '1'
            report "full metadata queue did not hold the pending acquisition" severity failure;
        lane_ready <= '1';
        for frame in 17 to 39 loop
            send_window(frame);
        end loop;
        wait until received = 40;
        wait for 100 ns;
        assert work_pending = '0' and chunk_busy = '0' and lane_valid = '0'
            report "lane failed to drain after metadata wrap and congestion" severity failure;
        report "tb_cnn_core_lane_metadata_capacity passed";
        stop;
        wait;
    end process;
end architecture sim;
