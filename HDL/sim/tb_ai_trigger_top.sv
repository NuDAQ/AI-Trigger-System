`timescale 1ns / 10ps
//==============================================================================
// tb_ai_trigger_top.sv
// Testbench for AI_TRIGGER_TOP (via AI_TRIGGER_TOP_TB_WRAP for mixed-language).
//
// Data format (same as cnn-core-wrapper testhex_stream):
//   testhex_dir/test_input_sample{N}.hex  — 256 lines x 64-bit word
//   testhex_dir/labels.hex                — 1000 x 32-bit label (0 or 1)
//
//   Each 64-bit hex word encodes one CNN timestep across 4 trigger channels:
//     bits [11: 0] = ch0,  12-bit signed (ap_fixed<12,6>)
//     bits [23:12] = ch1
//     bits [35:24] = ch2
//     bits [47:36] = ch3
//     bits [63:48] = 0 (unused)
//
//   One sample = 256 timesteps = 64 beats x 4 timesteps/beat.
//   The testbench presents 4 timesteps per DATA_STR pulse (one ADC source
//   clock cycle).  The DUT boundary is 8 raw ADC channels; this testbench
//   mirrors ch0..ch3 into ch4..ch7 so the event payload exercises all 8
//   channels while the CNN trigger still uses only ch0..ch3.
//
// Score decoding follows cnn-core-wrapper/hw/sim/tb_stream.sv:
//   float_score = $signed(CNN_OUT_DATA[21:0]) / 2048.0
// The core output is ap_fixed<22,11>, byte-aligned into a 32-bit TDATA word.
// The current full-system validation point uses SCORE_THRESHOLD=0.0, so the
// matching CNN_THRESH default is 22'sd0.
//
// Clocks:
//   ADC_SRC_CLK: 4 ns period (250 MHz)  — 1 GSa/s source beat clock
//   CLK_ADC: 4 ns period (250 MHz)      — trigger ingest clock
//   CLK_CNN:  5.000 ns period (200 MHz) — CNN inference clock
//
// Plusargs:
//   +TESTHEX_DIR=<path>     directory containing testhex_stream files
//   +OUT_CSV=<path>         output CSV path
//   +EVENT_CSV=<path>       event waveform CSV path
//   +NUM_SAMPLES=<N>        number of samples to run (default 1000)
//   +SCORE_THRESHOLD=<f>    classification threshold (default 0.0)
//   +CNN_THRESH_RAW=<N>     signed raw CNN_THRESH override (default 0)
//   +TRIGGER_MODE=<0..4>     runtime trigger mode (default 2, continuous AI)
//   +FORCE_TRIGGER_INTERVAL=<N>
//                           pulse FORCE_TRIGGER every N input chunks; 0=off
//   +FORCE_TRIGGER_BEAT=<0..63>
//                           scheduled pulse position within each selected chunk
//   +HL_THRESH=<0..2047>     Hi-Lo threshold in raw ADC codes (default 100)
//   +HILO_WINDOW=<0..31>     Hi-Lo intra-channel window (default 5)
//   +COINC_WINDOW=<0..63>    Hi-Lo coincidence window (default 3)
//   +BIN_THR=<1..4>          Hi-Lo channel multiplicity (default 1)
//   +MIRROR_RAW_CHANNELS=<0|1>
//                           mirror ch0..ch3 into raw event channels ch4..ch7
//                           (default 1 for legacy validation vectors)
//==============================================================================

module tb_AI_TRIGGER_TOP;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter ADC_SRC_CLK_PERIOD = 4.0;    // ns (250 MHz source beat clock)
    parameter CLK_ADC_PERIOD = 4.000;      // ns (250 MHz trigger ingest clock)
    parameter CLK_CNN_PERIOD =  5.000; // ns (200 MHz)

    parameter NUM_SAMPLES_DEFAULT = 1000;
    parameter NUM_SAMPLES_MAX     = 1000;
    parameter TIMEOUT_CYCLES_CNN  = 100_000_000;  // watchdog on CLK_CNN
    parameter OUTPUT_DRAIN_CYCLES = 8192;         // finish after input done + quiet CNN cycles

    parameter N_ADC_CH  = 8;
    parameter N_TRIGGER_CH = 4;
    parameter N_BATCH_S = 4;    // timesteps per beat
    parameter N_BATCHES = 64;   // beats per sample (64 * 4 = 256 timesteps)
    parameter N_CHUNK_W = 256;  // total CNN input words per sample

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    reg  clk_adc_src, clk_adc, clk_cnn, rst, data_str, event_ready;
    reg  [383:0] adc_data4_flat;  // 8 ch * 4 samples * 12-bit = 384 bits
    reg  [3:0]   trigger_mode;
    reg          force_trigger;
    reg  [31:0]  cnn_thresh;
    reg  [11:0]  hl_thresh;
    reg  [4:0]   hilo_window;
    reg  [5:0]   coinc_window;
    reg  [3:0]   bin_thr;

    wire         adc_src_ready;
    wire         adc_core_valid;
    wire         cnn_trig;
    wire [31:0]  cnn_out_data;
    wire [15:0]  cnn_out_chunk_id;
    wire         cnn_out_valid;
    wire         event_valid;
    wire [383:0] event_data;
    wire         event_last;
    wire [15:0]  event_chunk_id;
    wire [23:0]  event_timestamp;
    wire [5:0]   event_trigger_offset;
    wire [31:0]  event_score;
    wire [3:0]   active_trigger_mode;
    wire         mode_switch_pending;
    wire         invalid_trigger_mode;
    wire         hilo_config_error;
    wire         event_loss;
    wire [31:0]  adc_input_overflow_count;
    wire [31:0]  dropped_trigger_count;
    wire [31:0]  ring_miss_count;
    wire         chunk_overflow;

    // -------------------------------------------------------------------------
    // DUT instantiation (VHDL mixed-language bridge)
    // -------------------------------------------------------------------------
    AI_TRIGGER_TOP_TB_WRAP dut (
        .CLK_ADC        (clk_adc),
        .ADC_SRC_CLK    (clk_adc_src),
        .CLK_CNN        (clk_cnn),
        .RST            (rst),
        .DATA_STR       (data_str),
        .ADC_SRC_READY  (adc_src_ready),
        .ADC_CORE_VALID (adc_core_valid),
        .ADC_DATA4_FLAT (adc_data4_flat),
        .TRIGGER_MODE   (trigger_mode),
        .FORCE_TRIGGER  (force_trigger),
        .CNN_THRESH     (cnn_thresh),
        .HL_THRESH      (hl_thresh),
        .HILO_WINDOW    (hilo_window),
        .COINC_WINDOW   (coinc_window),
        .BIN_THR        (bin_thr),
        .CNN_TRIG       (cnn_trig),
        .CNN_OUT_DATA   (cnn_out_data),
        .CNN_OUT_CHUNK_ID (cnn_out_chunk_id),
        .CNN_OUT_VALID  (cnn_out_valid),
        .EVENT_VALID    (event_valid),
        .EVENT_READY    (event_ready),
        .EVENT_DATA     (event_data),
        .EVENT_LAST     (event_last),
        .EVENT_CHUNK_ID (event_chunk_id),
        .EVENT_TIMESTAMP (event_timestamp),
        .EVENT_TRIGGER_OFFSET (event_trigger_offset),
        .EVENT_SCORE    (event_score),
        .ACTIVE_TRIGGER_MODE (active_trigger_mode),
        .MODE_SWITCH_PENDING (mode_switch_pending),
        .INVALID_TRIGGER_MODE (invalid_trigger_mode),
        .HILO_CONFIG_ERROR (hilo_config_error),
        .EVENT_LOSS     (event_loss),
        .ADC_INPUT_OVERFLOW_COUNT (adc_input_overflow_count),
        .DROPPED_TRIGGER_COUNT (dropped_trigger_count),
        .RING_MISS_COUNT       (ring_miss_count),
        .CHUNK_OVERFLOW (chunk_overflow)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk_adc_src = 0;
    always #(ADC_SRC_CLK_PERIOD / 2.0) clk_adc_src = ~clk_adc_src;

    initial clk_adc = 0;
    always #(CLK_ADC_PERIOD / 2.0) clk_adc = ~clk_adc;

    initial clk_cnn = 0;
    always #(CLK_CNN_PERIOD / 2.0) clk_cnn = ~clk_cnn;

    // -------------------------------------------------------------------------
    // Simulation variables
    // -------------------------------------------------------------------------
    string  testhex_dir, out_csv_path, event_csv_path;
    integer csv_file, event_csv_file;
    integer num_samples;
    real    score_threshold;
    integer cnn_thresh_raw;
    integer trigger_mode_raw;
    integer force_trigger_interval;
    integer force_trigger_beat;
    integer hl_thresh_raw;
    integer hilo_window_raw;
    integer coinc_window_raw;
    integer bin_thr_raw;
    bit     has_score_threshold_arg;
    bit     has_cnn_thresh_raw_arg;
    integer mirror_raw_channels;

    // Per-sample hex storage (256 words)
    reg [63:0] sample_hex [0:N_CHUNK_W-1];
    reg [31:0] labels [0:NUM_SAMPLES_MAX-1];

    // Tracking
    integer sent_count    = 0;
    integer received_count = 0;
    integer correct_count  = 0;
    integer overflow_count = 0;
    integer event_count    = 0;
    integer event_batch_count = 0;
    bit input_done = 0;
    bit sim_done = 0;

    // Latency lookup indexed by DUT chunk/sample id.  Pressure tests may drop
    // chunks, so received_count is not a reliable proxy for the sample id.
    reg [63:0] start_time_by_sample [0:NUM_SAMPLES_MAX-1];
    reg [63:0] last_input_time_by_sample [0:NUM_SAMPLES_MAX-1];
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
        if (!$value$plusargs("EVENT_CSV=%s", event_csv_path))
            event_csv_path = "ai_trigger_events.csv";
        if (!$value$plusargs("NUM_SAMPLES=%d", num_samples))
            num_samples = NUM_SAMPLES_DEFAULT;
        if (num_samples <= 0 || num_samples > NUM_SAMPLES_MAX) begin
            $display("[ERROR] NUM_SAMPLES=%0d is outside supported range 1..%0d",
                     num_samples, NUM_SAMPLES_MAX);
            $finish;
        end
        has_score_threshold_arg = $value$plusargs("SCORE_THRESHOLD=%f", score_threshold);
        if (!has_score_threshold_arg)
            score_threshold = 0.0;
        has_cnn_thresh_raw_arg = $value$plusargs("CNN_THRESH_RAW=%d", cnn_thresh_raw);
        if (!has_cnn_thresh_raw_arg)
            cnn_thresh_raw = 0;  // 0.0 in ap_fixed<22,11>
        if (!has_score_threshold_arg && has_cnn_thresh_raw_arg)
            score_threshold = real'($signed(cnn_thresh_raw)) / 2048.0;
        if (!$value$plusargs("MIRROR_RAW_CHANNELS=%d", mirror_raw_channels))
            mirror_raw_channels = 1;
        if (!$value$plusargs("TRIGGER_MODE=%d", trigger_mode_raw))
            trigger_mode_raw = 2;
        if (!$value$plusargs("FORCE_TRIGGER_INTERVAL=%d", force_trigger_interval))
            force_trigger_interval = 0;
        if (!$value$plusargs("FORCE_TRIGGER_BEAT=%d", force_trigger_beat))
            force_trigger_beat = 31;
        if (!$value$plusargs("HL_THRESH=%d", hl_thresh_raw))
            hl_thresh_raw = 100;
        if (!$value$plusargs("HILO_WINDOW=%d", hilo_window_raw))
            hilo_window_raw = 5;
        if (!$value$plusargs("COINC_WINDOW=%d", coinc_window_raw))
            coinc_window_raw = 3;
        if (!$value$plusargs("BIN_THR=%d", bin_thr_raw))
            bin_thr_raw = 1;

        if (trigger_mode_raw < 0 || trigger_mode_raw > 4 ||
            force_trigger_interval < 0 ||
            force_trigger_beat < 0 || force_trigger_beat >= N_BATCHES ||
            hl_thresh_raw < 0 || hl_thresh_raw > 2047 ||
            hilo_window_raw < 0 || hilo_window_raw > 31 ||
            coinc_window_raw < 0 || coinc_window_raw > 63 ||
            bin_thr_raw < 1 || bin_thr_raw > 4) begin
            $fatal(1, "invalid multimode simulation configuration");
        end

        trigger_mode = trigger_mode_raw;
        force_trigger = 0;
        cnn_thresh    = cnn_thresh_raw;
        hl_thresh     = hl_thresh_raw;
        hilo_window   = hilo_window_raw;
        coinc_window  = coinc_window_raw;
        bin_thr       = bin_thr_raw;
        adc_data4_flat = 384'h0;
        data_str       = 0;
        event_ready    = 1;

        // CSV output
        csv_file = $fopen(out_csv_path, "w");
        if (csv_file == 0) begin
            $display("[ERROR] Cannot open CSV: %s", out_csv_path); $finish;
        end
        $fwrite(csv_file,
            "sample_id,hex_out,float_out,label,prediction,correct,latency_cycles_cnn,latency_us,input_first_fire_time_ns,input_last_fire_time_ns,cnn_result_time_ns\n");
        $fflush(csv_file);

        event_csv_file = $fopen(event_csv_path, "w");
        if (event_csv_file == 0) begin
            $display("[ERROR] Cannot open event CSV: %s", event_csv_path); $finish;
        end
        $fwrite(event_csv_file,
            "event_index,event_chunk_id,event_timestamp,event_trigger_offset,event_score_hex,event_batch_index,event_last,event_data_hex,event_output_time_ns,event_valid,event_ready,event_fire\n");
        $fflush(event_csv_file);

        // Load labels
        $readmemh($sformatf("%s/labels.hex", testhex_dir), labels);

        // Reset.  DATA_STR stays low until the input thread presents sample 0,
        // so the first hardware chunk is not polluted by reset-padding zeros.
        rst      = 1;
        data_str = 0;
        $display("[%0t] Asserting reset...", $time);
        repeat(10) @(posedge clk_cnn);
        repeat(4)  @(posedge clk_adc_src);
        repeat(4)  @(posedge clk_adc);
        rst      = 0;
        // Let FIFO Generator reset-busy/full flags settle before presenting
        // sample 0.  Otherwise the first chunk can be dropped and the monitor
        // will wait forever for the missing final result.
        repeat(32) @(posedge clk_adc);

        // The mode controller intentionally starts fail-closed and applies the
        // first request only at a complete chunk boundary.  Prime that boundary
        // with one ignored zero chunk so validation sample 0 remains chunk 0 in
        // the CSV artifacts.
        prime_trigger_mode();

        $display("[%0t] Starting AI_TRIGGER_TOP test", $time);
        $display("[%0t] TESTHEX_DIR: %s", $time, testhex_dir);
        $display("[%0t] Samples: %0d  Threshold raw: %0d (%.4f)",
                 $time, num_samples, cnn_thresh_raw, real'($signed(cnn_thresh_raw)) / 2048.0);
        $display("[%0t] MIRROR_RAW_CHANNELS: %0d", $time, mirror_raw_channels);
        $display("[%0t] TRIGGER_MODE: 0x%0h", $time, trigger_mode);
        $display("[%0t] FORCE_TRIGGER: every %0d chunks at beat %0d",
                 $time, force_trigger_interval, force_trigger_beat);
        $display("[%0t] Hi-Lo config: threshold=%0d hilo=%0d coincidence=%0d bin=%0d",
                 $time, hl_thresh_raw, hilo_window_raw, coinc_window_raw, bin_thr_raw);
        $display("---------------------------------------------------------------------");
        $display("Sample | Score (hex) | Score (float) | Label | Pred | Latency (us)");
        $display("---------------------------------------------------------------------");

        sim_start_time = $time;

        // Fork: send data on ADC clock, receive on CNN clock
        fork
            input_driver_thread();
            force_trigger_driver_thread();
            event_monitor_thread();
        join_none

        output_monitor_thread();
        drain_event_stream();
        disable fork;

        sim_end_time = $time;
        sim_done = 1;
        print_summary();
        $fclose(csv_file);
        $fclose(event_csv_file);
        $finish;
    end

    task automatic prime_trigger_mode;
        integer b;
        begin
            adc_data4_flat = 384'h0;
            force_trigger = 0;
            data_str = 1;
            for (b = 0; b < N_BATCHES; b = b + 1) begin
                do begin
                    @(posedge clk_adc_src);
                end while (!adc_src_ready);
            end
            data_str = 0;
            while (active_trigger_mode != trigger_mode || mode_switch_pending)
                @(posedge clk_adc);
            repeat(2) @(posedge clk_adc);
        end
    endtask

    // =========================================================================
    // Input driver (ADC source domain)
    //
    // DATA_STR is high exactly while this finite test stream is active.
    // The driver updates ADC_DATA4_FLAT every ADC source cycle to simulate the
    // continuous 1 Gsps ADC stream: 4 samples per cycle across 8 raw channels.
    //
    // Each sample occupies exactly N_BATCHES (64) consecutive source cycles.
    // Samples are streamed back-to-back with no gaps.
    // =========================================================================
    task automatic input_driver_thread;
        integer s_id, b, s, ch, w, sample_file;
        string  filename;
        reg [383:0] batch_flat;
        begin
            for (s_id = 0; s_id < num_samples; s_id = s_id + 1) begin
                filename = $sformatf("%s/test_input_sample%0d.hex", testhex_dir, s_id);
                sample_file = $fopen(filename, "r");
                if (sample_file == 0) begin
                    $display("[ERROR] Missing sample file for sample %0d: %s",
                             s_id, filename);
                    $finish;
                end
                $fclose(sample_file);

                for (w = 0; w < N_CHUNK_W; w = w + 1)
                    sample_hex[w] = 64'hx;
                $readmemh(filename, sample_hex);
                if ($isunknown(sample_hex[0]) ||
                    $isunknown(sample_hex[N_CHUNK_W-1])) begin
                    $display("[ERROR] Incomplete or invalid sample %0d: %s",
                             s_id, filename);
                    $finish;
                end

                // Drive 64 consecutive beats, one per source clock cycle.
                // Data changes on the rising edge (setup before posedge then hold).
                for (b = 0; b < N_BATCHES; b = b + 1) begin
                    batch_flat = 384'h0;
                    for (s = 0; s < N_BATCH_S; s = s + 1) begin
                        for (ch = 0; ch < N_ADC_CH; ch = ch + 1) begin
                            if (ch < N_TRIGGER_CH || mirror_raw_channels != 0) begin
                                batch_flat[(ch * N_BATCH_S + s) * 12 +: 12]
                                    = get_ch_sample(sample_hex[b * N_BATCH_S + s],
                                                    ch % N_TRIGGER_CH);
                            end else begin
                                batch_flat[(ch * N_BATCH_S + s) * 12 +: 12] = 12'h000;
                            end
                        end
                    end
                    adc_data4_flat = batch_flat;
                    data_str = 1;
                    do begin
                        @(posedge clk_adc_src);
                    end while (!adc_src_ready);
                    if (b == 0)
                        start_time_by_sample[s_id] = $time;
                    if (b == N_BATCHES - 1)
                        last_input_time_by_sample[s_id] = $time;
                end

                sent_count = sent_count + 1;
            end
            // After all requested samples, stop the finite test stream.
            adc_data4_flat = 384'h0;
            data_str = 0;
            input_done = 1;
        end
    endtask

    // FORCE_TRIGGER is synchronous to the delivered CLK_ADC boundary, while
    // testhex enters through the simulation-only source CDC FIFO. Count the
    // accepted core-side beats so the requested offset is not shifted by FIFO
    // latency. The default sweep uses beat 31, after the counter is established.
    task automatic force_trigger_driver_thread;
        integer core_beat_count;
        integer core_sample_id;
        integer core_beat_offset;
        begin
            core_beat_count = 0;
            force_trigger = 0;
            forever begin
                @(negedge clk_adc);
                force_trigger = 0;
                if (adc_core_valid) begin
                    core_sample_id = core_beat_count / N_BATCHES;
                    core_beat_offset = core_beat_count % N_BATCHES;
                    force_trigger = force_trigger_interval > 0 &&
                        core_beat_count < num_samples * N_BATCHES &&
                        (core_sample_id % force_trigger_interval) == 0 &&
                        core_beat_offset == force_trigger_beat;
                    core_beat_count = core_beat_count + 1;
                end
            end
        end
    endtask

    // =========================================================================
    // Event monitor (CLK_ADC domain)
    // Records the raw waveform event stream. One complete event is:
    // triggered chunk = 64 ADC beats.
    // =========================================================================
    task automatic event_monitor_thread;
        integer batch_in_event;
        time    previous_event_time_ns;
        time    expected_beat_period_ns;
        reg [15:0] previous_event_chunk_id;
        reg     have_previous_event_beat;
        begin
            batch_in_event = 0;
            previous_event_time_ns = 0;
            previous_event_chunk_id = 0;
            expected_beat_period_ns = time'($rtoi(CLK_ADC_PERIOD));
            have_previous_event_beat = 0;
            forever begin
                @(posedge clk_adc);
                if (event_valid && event_ready) begin
                    case (trigger_mode)
                        4'b0000, 4'b0010:
                            if (event_trigger_offset != 6'd0)
                                $fatal(1, "fixed-chunk event trigger offset must be zero, got %0d",
                                       event_trigger_offset);
                        4'b0001:
                            if (event_trigger_offset != force_trigger_beat)
                                $fatal(1, "external event trigger offset %0d, expected %0d",
                                       event_trigger_offset, force_trigger_beat);
                        4'b0011, 4'b0100:
                            if (event_trigger_offset[1:0] != 2'b11)
                                $fatal(1, "Hi-Lo event trigger offset must end a 4-beat aggregate, got %0d",
                                       event_trigger_offset);
                    endcase
                    if (have_previous_event_beat &&
                        (batch_in_event != 0 ||
                         ((trigger_mode == 4'b0000 || trigger_mode == 4'b0010) &&
                          event_chunk_id == previous_event_chunk_id + 16'd1)) &&
                        $time - previous_event_time_ns != expected_beat_period_ns) begin
                        $fatal(
                            1,
                            "Event output bubble: previous chunk=%0d current chunk=%0d batch=%0d delta=%0d ns expected=%0d ns",
                            previous_event_chunk_id,
                            event_chunk_id,
                            batch_in_event,
                            $time - previous_event_time_ns,
                            expected_beat_period_ns
                        );
                    end

                    $fwrite(event_csv_file,
                            "%0d,%0d,%0d,%0d,0x%08h,%0d,%0d,0x%096h,%0d,%0d,%0d,%0d\n",
                            event_count,
                            event_chunk_id - 16'd1,
                            event_timestamp - 24'd1,
                            event_trigger_offset,
                            event_score,
                            batch_in_event,
                            event_last,
                            event_data,
                            $time,
                            event_valid,
                            event_ready,
                            event_valid && event_ready);
                    $fflush(event_csv_file);

                    previous_event_time_ns = $time;
                    previous_event_chunk_id = event_chunk_id;
                    have_previous_event_beat = 1;
                    event_batch_count = event_batch_count + 1;
                    if (event_last) begin
                        event_count = event_count + 1;
                        batch_in_event = 0;
                    end else begin
                        batch_in_event = batch_in_event + 1;
                    end
                end
            end
        end
    endtask

    // =========================================================================
    // Event drain
    //
    // CNN results can arrive before the event-capture stream has finished
    // writing the corresponding triggered-chunk waveform.  Let the ADC-domain stream
    // settle before ending the testbench and killing event_monitor_thread().
    // =========================================================================
    task automatic drain_event_stream;
        integer quiet_cycles;
        begin
            quiet_cycles = 0;
            while (quiet_cycles < 96) begin
                @(posedge clk_adc);
                if (event_valid && event_ready) begin
                    quiet_cycles = 0;
                end else begin
                    quiet_cycles = quiet_cycles + 1;
                end
            end
        end
    endtask

    // =========================================================================
    // Output monitor (CLK_CNN domain)
    // Watches CNN_OUT_VALID, latches scores, computes accuracy.
    // =========================================================================
    task automatic output_monitor_thread;
        integer latency_cycles, output_quiet_cycles, sample_id_int;
        reg [63:0] t_start, t_last, t_end;
        real out_float;
        integer prediction, label_val, is_correct;
        begin
            output_quiet_cycles = 0;
            while (!input_done || output_quiet_cycles < OUTPUT_DRAIN_CYCLES) begin
                @(posedge clk_cnn);

                if (cnn_out_valid) begin
                    t_end = $time;
                    output_quiet_cycles = 0;
                    sample_id_int = $unsigned({16'h0000, cnn_out_chunk_id}) - 1;

                    if (trigger_mode == 4'b0010 &&
                        (sample_id_int < 0 || sample_id_int >= num_samples)) begin
                        $display("[ERROR] CNN_OUT_CHUNK_ID=%0d outside sample range 0..%0d",
                                 sample_id_int, num_samples - 1);
                        $finish;
                    end

                    // Continuous AI chunk ids identify dataset samples. Gated
                    // mode ids identify the centered work window's start chunk,
                    // which can legitimately precede sample zero.
                    if (sample_id_int >= 0 && sample_id_int < num_samples) begin
                        t_start = start_time_by_sample[sample_id_int];
                        t_last  = last_input_time_by_sample[sample_id_int];
                    end else begin
                        t_start = t_end;
                        t_last  = t_end;
                    end

                    latency_cycles = $rtoi((t_end - t_start) / CLK_CNN_PERIOD);

                    // Decode score: ap_fixed<22,11>, byte-aligned in [21:0].
                    out_float  = $itor($signed(cnn_out_data[21:0])) / 2048.0;
                    prediction = (out_float > score_threshold) ? 1 : 0;
                    if (trigger_mode == 4'b0010) begin
                        label_val  = labels[sample_id_int];
                        is_correct = (prediction == label_val) ? 1 : 0;
                    end else begin
                        label_val  = -1;
                        is_correct = -1;
                    end

                    if (is_correct == 1) correct_count = correct_count + 1;
                    total_latency_acc = total_latency_acc + latency_cycles;

                    $display("%6d | 0x%08h    | %13.6f | %5d | %4d | %10.3f",
                             sample_id_int, cnn_out_data, out_float,
                             label_val, prediction,
                             latency_cycles * CLK_CNN_PERIOD / 1000.0);

                    $fwrite(csv_file,
                            "%0d,0x%08h,%.6f,%0d,%0d,%0d,%0d,%.3f,%0d,%0d,%0d\n",
                            sample_id_int, cnn_out_data, out_float,
                            label_val, prediction, is_correct,
                            latency_cycles,
                            latency_cycles * CLK_CNN_PERIOD / 1000.0,
                            t_start,
                            t_last,
                            t_end);
                    $fflush(csv_file);

                    received_count = received_count + 1;
                end else if (input_done) begin
                    output_quiet_cycles = output_quiet_cycles + 1;
                end

                // Count overflows (sticky; sample once per CNN cycle)
                if (chunk_overflow) begin
                    overflow_count = overflow_count + 1;
                    $display("[ERROR] Unexpected chunk overflow after sending %0d samples, received %0d results",
                             sent_count, received_count);
                    $finish;
                end
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
            $display("CNN cores:        5 (parallel, round-robin)");
            $display("ADC_SRC_CLK:      %.1f MHz (%.3f ns period)",
                     1000.0/ADC_SRC_CLK_PERIOD, ADC_SRC_CLK_PERIOD);
            $display("CLK_ADC:          %.1f MHz (%.3f ns period)",
                     1000.0/CLK_ADC_PERIOD, CLK_ADC_PERIOD);
            $display("CLK_CNN:          %.1f MHz (%.3f ns period)",
                     1000.0/CLK_CNN_PERIOD, CLK_CNN_PERIOD);
            $display("CNN_THRESH:       %0d raw (%.4f float)",
                     cnn_thresh_raw, real'($signed(cnn_thresh_raw)) / 2048.0);
            $display("Score threshold:  %.4f float", score_threshold);
            $display("Requested mode:   0x%0h", trigger_mode);
            $display("Hi-Lo config:     threshold=%0d hilo=%0d coincidence=%0d bin=%0d",
                     hl_thresh_raw, hilo_window_raw, coinc_window_raw, bin_thr_raw);
            $display("-------------------------------------------------------------");
            $display("Samples sent:     %0d", sent_count);
            $display("Results received: %0d", received_count);
            $display("Output drain:     %0d quiet CLK_CNN cycles", OUTPUT_DRAIN_CYCLES);
            $display("Chunk overflows:  %0d (should be 0 in normal operation)",
                     overflow_count);
            $display("ADC input overflows: %0d", adc_input_overflow_count);
            $display("Events saved:     %0d", event_count);
            $display("Event batches:    %0d", event_batch_count);
            $display("Dropped triggers: %0d", dropped_trigger_count);
            $display("Ring misses:      %0d", ring_miss_count);
            $display("Active mode:      0x%0h", active_trigger_mode);
            $display("Mode pending:     %0d", mode_switch_pending);
            $display("Invalid mode:     %0d", invalid_trigger_mode);
            $display("Hi-Lo cfg error:  %0d", hilo_config_error);
            $display("Event loss:       %0d", event_loss);

            if (active_trigger_mode != trigger_mode || mode_switch_pending ||
                invalid_trigger_mode || hilo_config_error)
                $fatal(1, "multimode status mismatch in trigger-mode validation");
            if (event_loss && trigger_mode != 4'b0011 && trigger_mode != 4'b0100)
                $fatal(1, "unexpected event loss in housekeeping/continuous-AI validation");
            if (event_loss)
                $display("[WARNING] Hi-Lo raw requests were dropped while the centered window path was busy");

            if (received_count > 0) begin
                avg_latency   = total_latency_acc / received_count;
                total_time_us = (sim_end_time - sim_start_time) / 1000.0;
                throughput    = received_count / (total_time_us / 1_000_000.0);

                if (trigger_mode == 4'b0010) begin
                    accuracy = 100.0 * correct_count / received_count;
                    $display("Correct:          %0d / %0d (%.2f%%)",
                             correct_count, received_count, accuracy);
                end
                $display("-------------------------------------------------------------");
                $display("Avg latency:      %.1f CLK_CNN cycles  (%.3f us)",
                         avg_latency, avg_latency * CLK_CNN_PERIOD / 1000.0);
                $display("Total sim time:   %.3f us", total_time_us);
                $display("Throughput:       %.2f samples/sec", throughput);
            end
            $display("=============================================================");
            $display("Results saved to: %s", out_csv_path);
            $display("Events saved to:  %s", event_csv_path);
            $display("Simulation complete.");
        end
    endtask

    // =========================================================================
    // Watchdog (CLK_CNN domain)
    // =========================================================================
    initial begin
        repeat (TIMEOUT_CYCLES_CNN) @(posedge clk_cnn);
        if (!sim_done) begin
            $display("\n[ERROR] Watchdog timeout! sent %0d / %0d, received %0d",
                     sent_count, num_samples, received_count);
            print_summary();
            $finish;
        end
    end

endmodule
