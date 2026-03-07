library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pre_trigger_pkg.all;

entity CNN_FIFO_CONNECTOR is
    generic (
        C_CH0 : integer range 0 to 7 := 0;
        C_CH1 : integer range 0 to 7 := 1;
        C_CH2 : integer range 0 to 7 := 2;
        C_CH3 : integer range 0 to 7 := 3
    );
    port (
        -- Fast Clock Domain
        CLK_FAST      : in  std_logic;
        SYS_RST       : in  std_logic;
        DATA_STR      : in  std_logic;
        ADC_DATA8     : in  adc_data8_type;
        L0_PRE_TRIG   : in  std_logic;
        
        -- Slow Clock Domain (To CNN Wrapper)
        CLK_SLOW      : in  std_logic;
        CNN_START     : out std_logic;
        CNN_DONE      : in  std_logic;
        CNN_IDLE      : in  std_logic;
        CNN_READY     : in  std_logic;
        CNN_IN_DATA   : out std_logic_vector(63 downto 0);
        CNN_IN_VALID  : out std_logic;
        CNN_IN_READY  : in  std_logic
    );
end CNN_FIFO_CONNECTOR;

architecture rtl of CNN_FIFO_CONNECTOR is

    component fifo_async_1024_to_64
        port (
            rst      : in  std_logic;
            wr_clk   : in  std_logic;
            rd_clk   : in  std_logic;
            din      : in  std_logic_vector(1023 downto 0);
            wr_en    : in  std_logic;
            rd_en    : in  std_logic;
            dout     : out std_logic_vector(63 downto 0);
            full     : out std_logic;
            empty    : out std_logic
        );
    end component;

    signal fifo_din      : std_logic_vector(1023 downto 0);
    signal fifo_wr_en    : std_logic;
    signal fifo_rd_en    : std_logic;
    signal fifo_empty    : std_logic;
    signal cap_cnt       : integer range 0 to 15 := 0;

    type state_type is (ST_IDLE, ST_STREAM, ST_WAIT_DONE);
    signal cnn_state     : state_type := ST_IDLE;
    signal stream_cnt    : integer range 0 to 256 := 0;

begin

    u_ASYNC_FIFO : fifo_async_1024_to_64
        port map (
            rst      => SYS_RST,
            wr_clk   => CLK_FAST,
            rd_clk   => CLK_SLOW,
            din      => fifo_din,
            wr_en    => fifo_wr_en,
            rd_en    => fifo_rd_en,
            dout     => CNN_IN_DATA,
            full     => open,
            empty    => fifo_empty
        );

    -- Fast Domain: Pack 1024-bit word
    process(ADC_DATA8)
    begin
        for i in 0 to 15 loop
            fifo_din( (i*64)+63 downto (i*64) ) <= (x"0" & ADC_DATA8(C_CH3)(i)) & 
                                                   (x"0" & ADC_DATA8(C_CH2)(i)) & 
                                                   (x"0" & ADC_DATA8(C_CH1)(i)) & 
                                                   (x"0" & ADC_DATA8(C_CH0)(i));
        end loop;
    end process;

    -- Fast Domain: Capture Trigger Burst
    process(CLK_FAST)
    begin
        if rising_edge(CLK_FAST) then
            if SYS_RST = '1' then
                cap_cnt    <= 0;
                fifo_wr_en <= '0';
            else
                if cap_cnt > 0 then
                    fifo_wr_en <= '1';
                    cap_cnt    <= cap_cnt - 1;
                elsif L0_PRE_TRIG = '1' and DATA_STR = '1' then
                    fifo_wr_en <= '1';
                    cap_cnt    <= 15; 
                else
                    fifo_wr_en <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Slow Domain: CNN Interface FSM
    process(CLK_SLOW)
    begin
        if rising_edge(CLK_SLOW) then
            if SYS_RST = '1' then
                cnn_state    <= ST_IDLE;
                CNN_START    <= '0';
                fifo_rd_en   <= '0';
                CNN_IN_VALID <= '0';
                stream_cnt   <= 0;
            else
                case cnn_state is
                    when ST_IDLE =>
                        CNN_START  <= '0';
                        fifo_rd_en <= '0';
                        if fifo_empty = '0' and CNN_IDLE = '1' then
                            CNN_START  <= '1';
                            stream_cnt <= 256;
                            cnn_state  <= ST_STREAM;
                        end if;

                    when ST_STREAM =>
                        CNN_START <= '0';
                        if fifo_empty = '0' then
                            CNN_IN_VALID <= '1';
                            if CNN_IN_READY = '1' then
                                fifo_rd_en <= '1';
                                stream_cnt <= stream_cnt - 1;
                                if stream_cnt = 1 then
                                    cnn_state <= ST_WAIT_DONE;
                                end if;
                            else
                                fifo_rd_en <= '0';
                            end if;
                        else
                            CNN_IN_VALID <= '0';
                            fifo_rd_en   <= '0';
                        end if;

                    when ST_WAIT_DONE =>
                        CNN_IN_VALID <= '0';
                        fifo_rd_en   <= '0';
                        if CNN_DONE = '1' then
                            cnn_state <= ST_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;