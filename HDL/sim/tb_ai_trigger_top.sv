`timescale 1ns / 10ps
//==============================================================================
// tb_ai_trigger_top.sv
// Testbench for AI_TRIGGER_TOP (via AI_TRIGGER_TOP_TB_WRAP for mixed-language).
//
// Data format (same as cnn-core-wrapper testhex_stream):
//   testhex_dir/test_input_sample{N}.hex  — 256 lines x 64-bit word
//   testhex_dir/labels.hex                — 1000 x 32-bit label (0 or 1)
//
//   Each 64-bit hex word encodes one CNN timestep across 4 channels:
//     bits [11: 0] = ch0,  12-bit signed (ap_fixed<12,6>)
//     bits [23:12] = ch1
//     bits [35:24] = ch2
//     bits [47:36] = ch3
//     bits [63:48] = 0 (unused)
//
//   One sample = 256 timesteps = 16 batches x 16 timesteps/batch.
//   The testbench presents 16 timesteps per DATA_STR pulse (one CLK_ADC cycle).
//
// Score decoding follows cnn-core-wrapper/hw/sim/tb_stream.sv:
//   float_score = $signed(CNN_OUT_DATA[8:0]) / 16.0
// The core output is ap_fixed<9,5>, byte-aligned into a 16-bit TDATA word.
// The wrapper behavioral reference run uses SCORE_THRESHOLD=-6.0, so the
// matching CNN_THRESH default is 9'sd-96.
//
// Clocks:
//   CLK_ADC: 16 ns period (62.5 MHz)  — ADC batch clock
//   CLK_CNN:  5.882 ns period (170 MHz) — CNN inference clock
//
// Plusargs:
//   +TESTHEX_DIR=<path>     directory containing testhex_stream files
//   +OUT_CSV=<path>         output CSV path
//   +NUM_SAMPLES=<N>        number of samples to run (default 1000)
//   +SCORE_THRESHOLD=<f>    classification threshold (default -6.0)
//   +CNN_THRESH_RAW=<N>     signed raw CNN_THRESH override (default -96)
//==============================================================================

module tb_AI_TRIGGER_TOP;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter CLK_ADC_PERIOD = 16.0;   // ns (62.5 MHz)
    parameter CLK_CNN_PERIOD =  5.882352941; // ns (170 MHz)

    parameter NUM_SAMPLES_DEFAULT = 1000;
    parameter TIMEOUT_CYCLES_CNN  = 100_000_000;  // watchdog on CLK_CNN

    parameter N_CH      = 4;
    parameter N_BATCH_S = 16;   // timesteps per batch
    parameter N_BATCHES = 16;   // batches per sample (16 * 16 = 256 timesteps)
    parameter N_CHUNK_W = 256;  // total CNN input words per sample

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    reg  clk_adc, clk_cnn, rst, data_str;
    reg  [767:0] adc_data4_flat;  // 4 ch * 16 samples * 12-bit = 768 bits
    reg  [15:0]  cnn_thresh;

    wire         cnn_trig;
    wire [15:0]  cnn_out_data;
    wire         cnn_out_valid;
    wire         chunk_overflow;

    // -------------------------------------------------------------------------
    // DUT instantiation (VHDL mixed-language bridge)
    // -------------------------------------------------------------------------
    AI_TRIGGER_TOP_TB_WRAP dut (
        .CLK_ADC        (clk_adc),
        .CLK_CNN        (clk_cnn),
        .RST            (rst),
        .DATA_STR       (data_str),
        .ADC_DATA4_FLAT (adc_data4_flat),
        .CNN_THRESH     (cnn_thresh),
        .CNN_TRIG       (cnn_trig),
        .CNN_OUT_DATA   (cnn_out_data),
        .CNN_OUT_VALID  (cnn_out_valid),
        .CHUNK_OVERFLOW (chunk_overflow)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk_adc = 0;
    always #(CLK_ADC_PERIOD / 2.0) clk_adc = ~clk_adc;

    initial clk_cnn = 0;
    always #(CLK_CNN_PERIOD / 2.0) clk_cnn = ~clk_cnn;

    // -------------------------------------------------------------------------
    // Simulation variables
    // -------------------------------------------------------------------------
    string  testhex_dir, out_csv_path;
    integer csv_file;
    integer num_samples;
    real    score_threshold;
    integer cnn_thresh_raw;

    // Per-sample hex storage (256 words)
    reg [63:0] sample_hex [0:N_CHUNK_W-1];
    reg [31:0] labels [0:999];

    // Tracking
    integer sent_count    = 0;
    integer received_count = 0;
    integer correct_count  = 0;
    integer overflow_count = 0;

    // Latency FIFO (record send time per sample, match with received results)
    reg [63:0] start_time_fifo [0:2047];
    integer fifo_head = 0, fifo_tail = 0;
    real total_latency_acc = 0;

    reg [63:0] sim_start_time, sim_end_time;

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------
    // Extract 12-bit channel value from packed 64-bit hex word
    function automatic [11:0] get_ch_sample(input [63:0] word, input integer ch);
        case (ch)
            0: get_ch_sample = word[11: 0];
            1: get_ch_sample = word[23:12];
            2: get_ch_sample = word[35:24];
            3: get_ch_sample = word[47:36];
            default: get_ch_sample = 12'h0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        // Plusargs
        if (!$value$plusargs("TESTHEX_DIR=%s", testhex_dir))
            testhex_dir = "testhex_stream";
        if (!$value$plusargs("OUT_CSV=%s", out_csv_path))
            out_csv_path = "ai_trigger_results.csv";
        if (!$value$plusargs("NUM_SAMPLES=%d", num_samples))
            num_samples = NUM_SAMPLES_DEFAULT;
        if (!$value$plusargs("SCORE_THRESHOLD=%f", score_threshold))
            score_threshold = -6.0;
        if (!$value$plusargs("CNN_THRESH_RAW=%d", cnn_thresh_raw))
            cnn_thresh_raw = -96;  // -6.0 in ap_fixed<9,5>

        cnn_thresh    = $signed(cnn_thresh_raw[15:0]);
        adc_data4_flat = 768'h0;
        data_str       = 0;

        // CSV output
        csv_file = $fopen(out_csv_path, "w");
        if (csv_file == 0) begin
            $display("[ERROR] Cannot open CSV: %s", out_csv_path); $finish;
        end
        $fwrite(csv_file,
            "sample_id,hex_out,float_out,label,prediction,correct,latency_cycles_cnn,latency_us\n");
        $fflush(csv_file);

        // Load labels
        $readmemh($sformatf("%s/labels.hex", testhex_dir), labels);

        // Reset.  DATA_STR stays low until the input thread presents sample 0,
        // so the first hardware chunk is not polluted by reset-padding zeros.
        rst      = 1;
        data_str = 0;
        $display("[%0t] Asserting reset...", $time);
        repeat(10) @(posedge clk_cnn);
        repeat(4)  @(posedge clk_adc);
        rst      = 0;
        // Let FIFO Generator reset-busy/full flags settle before presenting
        // sample 0.  Otherwise the first chunk can be dropped and the monitor
        // will wait forever for the missing final result.
        repeat(32) @(posedge clk_adc);

        $display("[%0t] Starting AI_TRIGGER_TOP test", $time);
        $display("[%0t] TESTHEX_DIR: %s", $time, testhex_dir);
        $display("[%0t] Samples: %0d  Threshold raw: %0d (%.4f)",
                 $time, num_samples, cnn_thresh_raw, real'($signed(cnn_thresh_raw)) / 16.0);
        $display("---------------------------------------------------------------------");
        $display("Sample | Score (hex) | Score (float) | Label | Pred | Latency (us)");
        $display("---------------------------------------------------------------------");

        sim_start_time = $time;

        // Fork: send data on ADC clock, receive on CNN clock
        fork
            input_driver_thread();
        join_none

        output_monitor_thread();
        disable fork;

        sim_end_time = $time;
        print_summary();
        $fclose(csv_file);
        $finish;
    end

    // =========================================================================
    // Input driver (CLK_ADC domain)
    //
    // DATA_STR is high exactly while this finite test stream is active.
    // The driver updates ADC_DATA4_FLAT every CLK_ADC cycle to simulate the
    // continuous 1 Gsps ADC stream: 16 samples per cycle across 4 channels.
    //
    // Each sample occupies exactly N_BATCHES (16) consecutive CLK_ADC cycles.
    // Samples are streamed back-to-back with no gaps.
    // =========================================================================
    task automatic input_driver_thread;
        integer s_id, b, s, ch;
        string  filename;
        reg [767:0] batch_flat;
        begin
            for (s_id = 0; s_id < num_samples; s_id = s_id + 1) begin
                filename = $sformatf("%s/test_input_sample%0d.hex", testhex_dir, s_id);
                $readmemh(filename, sample_hex);
                if (sample_hex[0] === 64'bx) begin
                    $display("[ERROR] Failed to load %s", filename); $finish;
                end

                // Record send time for latency measurement
                start_time_fifo[fifo_tail] = $time;
                fifo_tail = (fifo_tail + 1) % 2048;

                // Drive 16 consecutive batches, one per CLK_ADC cycle.
                // Data changes on the rising edge (setup before posedge then hold).
                for (b = 0; b < N_BATCHES; b = b + 1) begin
                    batch_flat = 768'h0;
                    for (s = 0; s < N_BATCH_S; s = s + 1) begin
                        for (ch = 0; ch < N_CH; ch = ch + 1) begin
                            batch_flat[(ch * N_BATCH_S + s) * 12 +: 12]
                                = get_ch_sample(sample_hex[b * N_BATCH_S + s], ch);
                        end
                    end
                    adc_data4_flat = batch_flat;
                    data_str = 1;
                    @(posedge clk_adc);   // hold for exactly 1 cycle; no gap
                end

                sent_count = sent_count + 1;
            end
            // After all requested samples, stop the finite test stream.
            adc_data4_flat = 768'h0;
            data_str = 0;
        end
    endtask

    // =========================================================================
    // Output monitor (CLK_CNN domain)
    // Watches CNN_OUT_VALID, latches scores, computes accuracy.
    // =========================================================================
    task automatic output_monitor_thread;
        integer latency_cycles;
        reg [63:0] t_start, t_end;
        real out_float;
        integer prediction, label_val, is_correct;
        begin
            while (received_count < num_samples) begin
                @(posedge clk_cnn);

                if (cnn_out_valid) begin
                    t_end = $time;

                    // Retrieve matching send time from FIFO
                    if (fifo_head != fifo_tail) begin
                        t_start  = start_time_fifo[fifo_head];
                        fifo_head = (fifo_head + 1) % 2048;
                    end else begin
                        t_start = t_end;
                    end

                    latency_cycles = (t_end - t_start) / CLK_CNN_PERIOD;

                    // Decode score: ap_fixed<9,5>, byte-aligned in [8:0].
                    out_float  = $itor($signed(cnn_out_data[8:0])) / 16.0;
                    prediction = (out_float > score_threshold) ? 1 : 0;
                    label_val  = labels[received_count];
                    is_correct = (prediction == label_val) ? 1 : 0;

                    if (is_correct) correct_count = correct_count + 1;
                    total_latency_acc = total_latency_acc + latency_cycles;

                    $display("%6d | 0x%04h        | %13.6f | %5d | %4d | %10.3f",
                             received_count, cnn_out_data, out_float,
                             label_val, prediction,
                             latency_cycles * CLK_CNN_PERIOD / 1000.0);

                    $fwrite(csv_file, "%0d,0x%04h,%.6f,%0d,%0d,%0d,%0d,%.3f\n",
                            received_count, cnn_out_data, out_float,
                            label_val, prediction, is_correct,
                            latency_cycles,
                            latency_cycles * CLK_CNN_PERIOD / 1000.0);
                    $fflush(csv_file);

                    received_count = received_count + 1;
                end

                // Count overflows (sticky; sample once per CNN cycle)
                if (chunk_overflow) overflow_count = overflow_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Summary
    // =========================================================================
    task automatic print_summary;
        real avg_latency, total_time_us, throughput, accuracy;
        begin
            $display("\n=============================================================");
            $display("                    SIMULATION SUMMARY");
            $display("=============================================================");
            $display("Top module:       AI_TRIGGER_TOP");
            $display("CNN cores:        7 (parallel, round-robin)");
            $display("CLK_ADC:          %.1f MHz (%.0f ns period)",
                     1000.0/CLK_ADC_PERIOD, CLK_ADC_PERIOD);
            $display("CLK_CNN:          %.1f MHz (%.3f ns period)",
                     1000.0/CLK_CNN_PERIOD, CLK_CNN_PERIOD);
            $display("CNN_THRESH:       %0d raw (%.4f float)",
                     cnn_thresh_raw, real'($signed(cnn_thresh_raw)) / 16.0);
            $display("-------------------------------------------------------------");
            $display("Samples sent:     %0d", sent_count);
            $display("Results received: %0d", received_count);
            $display("Chunk overflows:  %0d (should be 0 in normal operation)",
                     overflow_count);

            if (received_count > 0) begin
                accuracy      = 100.0 * correct_count / received_count;
                avg_latency   = total_latency_acc / received_count;
                total_time_us = (sim_end_time - sim_start_time) / 1000.0;
                throughput    = received_count / (total_time_us / 1_000_000.0);

                $display("Correct:          %0d / %0d (%.2f%%)",
                         correct_count, received_count, accuracy);
                $display("-------------------------------------------------------------");
                $display("Avg latency:      %.1f CLK_CNN cycles  (%.3f us)",
                         avg_latency, avg_latency * CLK_CNN_PERIOD / 1000.0);
                $display("Total sim time:   %.3f us", total_time_us);
                $display("Throughput:       %.2f samples/sec", throughput);
            end
            $display("=============================================================");
            $display("Results saved to: %s", out_csv_path);
            $display("Simulation complete.");
        end
    endtask

    // =========================================================================
    // Watchdog (CLK_CNN domain)
    // =========================================================================
    initial begin
        repeat (TIMEOUT_CYCLES_CNN) @(posedge clk_cnn);
        if (received_count < num_samples) begin
            $display("\n[ERROR] Watchdog timeout! received %0d / %0d",
                     received_count, num_samples);
            print_summary();
            $finish;
        end
    end

endmodule
