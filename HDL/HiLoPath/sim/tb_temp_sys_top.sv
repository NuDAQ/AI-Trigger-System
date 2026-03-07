`timescale 1ns / 10ps

module tb_TEMP_SYS_TOP;

    parameter FAST_CLK_PERIOD = 16.0; // 62.5 MHz (1GHz ADC / 16 samples)
    parameter SLOW_CLK_PERIOD = 5.0;  // 200 MHz CNN clock

    // Signals
    reg  clk_fast = 0;
    reg  clk_slow = 0;
    reg  sys_rst;
    reg  data_str;
    
    // Multi-dimensional array mirroring the VHDL adc_data8_type
    reg [11:0] adc_data_tb [0:7][0:15];

    // Flat packed wire for VHDL port adc_data8_type (8 * 16 * 12 = 1536 bits).
    // Vivado xsim mixed-language: VHDL user-defined array ports must connect as
    // an equivalent-width flat vector from the SV side.
    // Packing convention (MSB-first, matching VHDL array(0 to N)):
    //   adc_data_tb[ch][s]  ->  adc_data_flat[1535 - (ch*16+s)*12  -: 12]
    wire [1535:0] adc_data_flat;
    genvar gi, gj;
    generate
        for (gi = 0; gi < 8; gi++) begin : gen_ch
            for (gj = 0; gj < 16; gj++) begin : gen_s
                assign adc_data_flat[1535 - (gi*16+gj)*12 -: 12] = adc_data_tb[gi][gj];
            end
        end
    endgenerate

    wire        l0_pre_trig;
    wire [31:0] cnn_out_data;
    wire        cnn_out_valid;
    reg         cnn_out_ready;

    // -------------------------------------------------------------------------
    // Event Memory Load
    // -------------------------------------------------------------------------
    // 1000 events, 256 timesteps per event = 256,000 lines
    // Each line is 48 bits (4 channels * 12 bits)
    reg [47:0] event_mem [0:255999];
    reg [31:0] label_mem [0:999];
    
    initial begin
        // Load the pure signal hex files
        // (Use absolute paths if Vivado complains it cannot find them)
        $readmemh("/home/work1/Works/AI-Trigger-System/data/real_events.hex", event_mem);
        $readmemh("/home/work1/Works/AI-Trigger-System/data/real_labels.hex", label_mem);
    end

    // -------------------------------------------------------------------------
    // Device Under Test
    // -------------------------------------------------------------------------
    TEMP_SYS_TOP uut (
        .CLK_FAST      (clk_fast),
        .CLK_SLOW      (clk_slow),
        .SYS_RST       (sys_rst),
        .DATA_STR      (data_str),
        .ADC_DATA8     (adc_data_flat),
        .L0_PRE_TRIG   (l0_pre_trig),
        .CNN_OUT_DATA  (cnn_out_data),
        .CNN_OUT_VALID (cnn_out_valid),
        .CNN_OUT_READY (cnn_out_ready)
    );

    // Clocks
    always #(FAST_CLK_PERIOD/2.0) clk_fast = ~clk_fast;
    always #(SLOW_CLK_PERIOD/2.0) clk_slow = ~clk_slow;

    // -------------------------------------------------------------------------
    // Background Noise Generator
    // -------------------------------------------------------------------------
    reg injecting_event = 0;

    // Continual background noise driver for the idle baseline
    always @(posedge clk_fast) begin
        if (data_str == 1 && !injecting_event) begin
            for (int c = 0; c < 8; c++) begin
                for (int s = 0; s < 16; s++) begin
                    // Max noise is 2047 (0x7FF). 
                    // Stays just below the 0x800 trigger threshold to prevent false firing!
                    adc_data_tb[c][s] <= 12'(2040 + ({$random} % 8));
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main Test Stimulus & Injection Engine
    // -------------------------------------------------------------------------
    initial begin
        $display("[%0t] Starting Dynamic Event Simulation...", $time);
        
        sys_rst         = 1;
        data_str        = 0;
        cnn_out_ready   = 1;
        injecting_event = 0;

        // Init Arrays
        for (int c = 0; c < 8; c++) begin
            for (int s = 0; s < 16; s++) begin
                adc_data_tb[c][s] = 12'h000;
            end
        end

        // Wait for Reset
        repeat(20) @(posedge clk_fast);
        sys_rst = 0;
        repeat(10) @(posedge clk_fast);

        $display("[%0t] Activating data strobe and background noise...", $time);
        data_str = 1; 
        
        // Let the noise settle
        repeat(100) @(posedge clk_fast);
        
        // ---------------------------------------------------------
        // Dynamic Injection Loop
        // ---------------------------------------------------------
        // Simulate 5 random events from the dataset
        for (int test_ev = 0; test_ev < 5; test_ev++) begin
            integer delay_cycles;
            integer rand_event_idx;
            integer mem_idx;
            reg [47:0] mem_line;
            
            // 1. Wait a random delay (background noise continues automatically)
            delay_cycles = 100 + ({$random} % 400); 
            repeat(delay_cycles) @(posedge clk_fast);
            
            // 2. Pick a random event from the 1000 loaded datasets
            rand_event_idx = {$random} % 1000;
            
            $display("===================================================================");
            $display("[%0t] INJECTING EVENT #%0d (Truth Label: %0d)", $time, rand_event_idx, label_mem[rand_event_idx]);
            $display("===================================================================");
            
            // 3. Inject it (16 batches * 16 timesteps = 256 timesteps)
            injecting_event = 1; // Yield control from the background noise generator
            
            for (int batch = 0; batch < 16; batch++) begin
                @(posedge clk_fast);
                for (int s = 0; s < 16; s++) begin
                    mem_idx = (rand_event_idx * 256) + (batch * 16) + s;
                    mem_line = event_mem[mem_idx];
                    
                    // Loop through the 4 active CNN channels
                    for (int c = 0; c < 4; c++) begin
                        logic [11:0] noise;
                        logic [11:0] pure_sig;
                        logic [11:0] combined_signal;
                        
                        // 3A. Generate algorithmic baseline noise
                        noise = 12'(2040 + ({$random} % 8)); 
                        
                        // 3B. Extract the pure 12-bit two's complement signal
                        if      (c == 0) pure_sig = mem_line[11:0];
                        else if (c == 1) pure_sig = mem_line[23:12];
                        else if (c == 2) pure_sig = mem_line[35:24];
                        else             pure_sig = mem_line[47:36];
                        
                        // 3C. Superimpose signal onto noise 
                        // Standard binary addition natively handles the two's complement offset
                        combined_signal = noise + pure_sig;
                        
                        // 3D. Apply to the primary channels (0-3) for the CNN
                        adc_data_tb[c][s] <= combined_signal;
                        
                        // 3E. Mirror to the upper channels (4-7) for the storage backend path
                        adc_data_tb[c+4][s] <= combined_signal;
                    end
                end
            end
            
            // 4. Return control to the background noise generator
            @(posedge clk_fast); 
            injecting_event = 0;
            
            // 5. Wait for L1 CNN inference
            fork
                begin
                    wait(cnn_out_valid == 1);
                    $display("[%0t] SUCCESS: CNN output valid! Prediction/Data: 0x%08h", $time, cnn_out_data);
                    wait(cnn_out_valid == 0); // Wait for the handshake to clear before starting next event
                end
                begin
                    #150000;
                    $display("[%0t] TIMEOUT: No output from CNN. (Did signal amplitude fail to cross threshold?)", $time);
                end
            join_any
            disable fork; // Kill the timeout if the wait succeeds
        end

        // Flush out the rest of the simulation
        repeat(100) @(posedge clk_slow);
        $display("[%0t] All test injections complete.", $time);
        $finish;
    end
endmodule