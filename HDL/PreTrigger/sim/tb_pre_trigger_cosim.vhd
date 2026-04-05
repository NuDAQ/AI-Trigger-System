-- =============================================================================
--  tb_pre_trigger_cosim.vhd
--  Data-Driven Co-Simulation Testbench for PRE_TRIGGER
--
--  Reads:  ../../../analysis/PreTrigger/stimulus.txt 
--  Writes: ../../../analysis/PreTrigger/hw_resp_thr_XXX.txt 
--
--  Parameters:
--    BIN_THR      = 2 (N=2 Coincidence for 4-channel Hi-Lo)
--    HILO_WINDOW  = 5
--    COINC_WINDOW = 32
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.pre_trigger_pkg.all;

entity tb_pre_trigger_cosim is
end entity;

architecture sim of tb_pre_trigger_cosim is

    -- DUT interface
    signal CLK          : std_logic := '0';
    signal RESET        : std_logic := '1';
    signal DATA_STR     : std_logic := '0';
    signal ADC_DATA4    : adc_data4_type := (others => (others => (others => '0')));
    signal THRESH       : std_logic_vector(11 downto 0);
    signal HILO_WINDOW  : std_logic_vector( 4 downto 0);
    signal COINC_WINDOW : std_logic_vector( 5 downto 0);
    signal BIN_THR      : std_logic_vector( 3 downto 0);
    signal PRE_TRIG     : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    -- =========================================================================
    -- SWEEP CONFIGURATION
    -- Target RMS steps: 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0
    -- Formula: integer(RMS_Step * noise_rms * 64)
    -- WARNING: These integers assume noise_rms = 1.0. 
    -- You MUST update these integers using your actual Python noise_rms!
    -- =========================================================================
    type int_array is array (0 to 6) of integer;
    constant THRESH_SWEEP : int_array := (
        128,  -- 2.0 * 64
        160,  -- 2.5 * 64
        192,  -- 3.0 * 64
        224,  -- 3.5 * 64
        256,  -- 4.0 * 64
        288,  -- 4.5 * 64
        320   -- 5.0 * 64
    );

begin

    -- Instantiate the Top-Level 4-Channel Trigger
    U_DUT : entity work.PRE_TRIGGER
        port map (
            CLK          => CLK,
            RESET        => RESET,
            DATA_STR     => DATA_STR,
            ADC_DATA4    => ADC_DATA4,
            THRESH       => THRESH,
            HILO_WINDOW  => HILO_WINDOW,
            COINC_WINDOW => COINC_WINDOW,
            BIN_THR      => BIN_THR,
            PRE_TRIG     => PRE_TRIG
        );

    -- Clock Generation
    CLK <= not CLK after CLK_PERIOD / 2;

    -- File I/O and Stimulus Process
    stimulus : process
        file stim_file      : text;
        file resp_file      : text;
        variable in_line    : line;
        variable out_line   : line;
        variable val        : integer;
        variable batch      : adc_data4_type;
    begin
        -- Static Configuration
        HILO_WINDOW  <= "00101";  -- 5 samples
        COINC_WINDOW <= "100000"; -- 32 samples
        BIN_THR      <= x"2";     -- N=2 Coincidence 

        -- Loop through the 7 threshold values
        for i in 0 to 6 loop
            
            -- 1. Apply the new hardware threshold
            THRESH <= std_logic_vector(to_signed(THRESH_SWEEP(i), 12));

            -- 2. Hard Reset the DUT for a clean run
            RESET <= '1';
            DATA_STR <= '0';
            ADC_DATA4 <= (others => (others => (others => '0')));
            wait until rising_edge(CLK);
            wait until rising_edge(CLK);
            RESET <= '0';
            wait until rising_edge(CLK);

            -- 3. Open the files using relative paths bridging the HDL and analysis directories
            file_open(stim_file, "../../../analysis/PreTrigger/stimulus.txt", read_mode);
            file_open(resp_file, "../../../analysis/PreTrigger/hw_resp_thr_" & integer'image(THRESH_SWEEP(i)) & ".txt", write_mode);

            report "=== Starting sweep for Threshold: " & integer'image(THRESH_SWEEP(i)) & " ===";

            -- 4. Stream the data into the pipeline
            while not endfile(stim_file) loop
                readline(stim_file, in_line);

                -- Parse the 128 integers (4 channels * 32 samples)
                for ch in 0 to 3 loop
                    for samp in 0 to 31 loop
                        read(in_line, val);
                        batch(ch)(samp) := std_logic_vector(to_signed(val, 12));
                    end loop;
                end loop;

                ADC_DATA4 <= batch;
                DATA_STR  <= '1';

                wait until rising_edge(CLK);

                -- Write hardware response (Latent output from 2 cycles prior)
                if PRE_TRIG = '1' then
                    write(out_line, string'("1"));
                else
                    write(out_line, string'("0"));
                end if;
                writeline(resp_file, out_line);
            end loop;

            -- 5. Flush the 2-cycle pipeline latency at the end of the file
            DATA_STR <= '0';
            for j in 1 to 2 loop
                wait until rising_edge(CLK);
                if PRE_TRIG = '1' then
                    write(out_line, string'("1"));
                else
                    write(out_line, string'("0"));
                end if;
                writeline(resp_file, out_line);
            end loop;

            -- 6. Close the files to prep for the next iteration
            file_close(stim_file);
            file_close(resp_file);

            report "=== Completed sweep for Threshold: " & integer'image(THRESH_SWEEP(i)) & " ===";
            
            -- Wait a few cycles before starting the next sweep to cleanly separate waveforms in GTKWave
            wait for 50 ns;
            
        end loop;

        report "ALL 7 SWEEPS COMPLETED SUCCESSFULLY.";
        std.env.finish;
    end process;

end architecture;