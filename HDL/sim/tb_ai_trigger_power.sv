`timescale 1ns/1ps

// Post-route activity testbench for the DAQ-facing production top.
module tb_ai_trigger_power;
    localparam MAX_WINDOWS = 2048;
    localparam BEATS_PER_CHUNK = 64;

    reg clk_adc = 0;
    reg clk_cnn = 0;
    reg rst = 1;
    reg data_str = 0;
    reg [383:0] adc_data = 0;
    reg [3:0] trigger_mode = 4'd2;
    reg [31:0] threshold = 0;

    always #2.0 clk_adc = ~clk_adc;
    always #2.5 clk_cnn = ~clk_cnn;

    wire event_valid;
    wire [383:0] event_data;
    wire event_last;
    wire [23:0] event_timestamp;
    wire [5:0] event_trigger_offset;
    wire [3:0] active_trigger_mode;
    wire mode_switch_pending;
    wire invalid_trigger_mode;
    wire hilo_blanking;
    wire hilo_config_error;
    wire event_loss;

    reg [383:0] adc_words [0:MAX_WINDOWS * BEATS_PER_CHUNK - 1];
    reg [31:0] expected_scores [0:MAX_WINDOWS - 1];
    bit event_seen [0:MAX_WINDOWS - 1];

    string reference;
    integer chunks = 30;
    integer start_window = 96;
    integer expected_events = 0;
    integer event_count = 0;
    integer event_beat = 0;
    integer local_chunk;
    integer reference_chunk;
    integer drain_boundaries = 0;
    bit switch_requested = 0;

    function automatic bit qualifies(
        input reg [31:0] native_score,
        input reg [31:0] external_threshold
    );
        qualifies = ($itor($signed(native_score[20:0])) / 512.0) >
                    ($itor($signed(external_threshold)) / 16.0);
    endfunction

    AI_TRIGGER_TOP dut (
        .CLK_ADC(clk_adc),
        .CLK_CNN(clk_cnn),
        .RST(rst),
        .DATA_STR(data_str),
        .ADC_DATA(adc_data),
        .TRIGGER_MODE(trigger_mode),
        .FORCE_TRIGGER(1'b0),
        .CNN_THRESH(threshold),
        .HL_THRESH(12'd100),
        .HILO_WINDOW(8'd5),
        .COINC_WINDOW(8'd3),
        .BIN_THR(4'd1),
        .EVENT_VALID(event_valid),
        .EVENT_READY(1'b1),
        .EVENT_DATA(event_data),
        .EVENT_LAST(event_last),
        .EVENT_TIMESTAMP(event_timestamp),
        .EVENT_TRIGGER_OFFSET(event_trigger_offset),
        .ACTIVE_TRIGGER_MODE(active_trigger_mode),
        .MODE_SWITCH_PENDING(mode_switch_pending),
        .INVALID_TRIGGER_MODE(invalid_trigger_mode),
        .HILO_BLANKING(hilo_blanking),
        .HILO_CONFIG_ERROR(hilo_config_error),
        .EVENT_LOSS(event_loss)
    );

    always @(posedge clk_adc) begin
        if (!rst && active_trigger_mode == 4'd2) begin
            if (event_loss || hilo_blanking || hilo_config_error ||
                (invalid_trigger_mode && !switch_requested))
                $fatal(1, "unexpected production status during measured activity");

            if (event_valid) begin
                local_chunk = int'(event_timestamp);
                if (local_chunk < 1 || local_chunk > chunks)
                    $fatal(1, "event timestamp outside measured chunks: %0d", local_chunk);
                reference_chunk = start_window + local_chunk - 1;
                if (!qualifies(expected_scores[reference_chunk], threshold))
                    $fatal(1, "nonqualifying chunk emitted event: %0d", local_chunk);
                if (event_seen[local_chunk - 1])
                    $fatal(1, "duplicate event for chunk: %0d", local_chunk);
                if (event_data !== adc_words[reference_chunk * BEATS_PER_CHUNK + event_beat])
                    $fatal(1, "event waveform mismatch chunk=%0d beat=%0d",
                           local_chunk, event_beat);
                if (event_trigger_offset !== 0)
                    $fatal(1, "continuous AI event offset is not zero");
                if (event_last !== (event_beat == BEATS_PER_CHUNK - 1))
                    $fatal(1, "event framing mismatch chunk=%0d beat=%0d",
                           local_chunk, event_beat);

                if (event_beat == BEATS_PER_CHUNK - 1) begin
                    event_seen[local_chunk - 1] = 1;
                    event_count = event_count + 1;
                    event_beat = 0;
                end else begin
                    event_beat = event_beat + 1;
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("REFERENCE=%s", reference))
            $fatal(1, "missing REFERENCE plusarg");
        void'($value$plusargs("CHUNKS=%d", chunks));
        void'($value$plusargs("START_WINDOW=%d", start_window));
        void'($value$plusargs("THRESHOLD=%h", threshold));

        if (chunks < 1 || start_window < 0 || start_window + chunks > MAX_WINDOWS)
            $fatal(1, "invalid reference range");

        $readmemh({reference, "/adc.hex"}, adc_words);
        $readmemh({reference, "/all_expected.hex"}, expected_scores);
        for (integer i = 0; i < chunks; i = i + 1) begin
            event_seen[i] = 0;
            if (qualifies(expected_scores[start_window + i], threshold))
                expected_events = expected_events + 1;
        end

        repeat (40) @(negedge clk_adc);
        rst = 0;
        repeat (40) @(negedge clk_adc);

        // The first complete chunk arms the mode controller and is not inferred.
        data_str = 1;
        repeat (BEATS_PER_CHUNK) @(negedge clk_adc);
        data_str = 0;
        wait (active_trigger_mode == 4'd2);
        repeat (20) @(negedge clk_adc);

        for (integer i = 0; i < chunks * BEATS_PER_CHUNK; i = i + 1) begin
            adc_data = adc_words[start_window * BEATS_PER_CHUNK + i];
            data_str = 1;
            if (i == chunks * BEATS_PER_CHUNK - 1) begin
                trigger_mode = 4'hf;
                switch_requested = 1;
            end
            @(negedge clk_adc);
        end
        data_str = 0;

        // Draining suppresses new CNN work. Supply boundaries until the mode
        // controller can finish the pending switch after all measured work.
        while (active_trigger_mode != 4'hf) begin
            drain_boundaries = drain_boundaries + 1;
            if (drain_boundaries > 16)
                $fatal(1, "mode drain did not complete");
            adc_data = 0;
            data_str = 1;
            repeat (BEATS_PER_CHUNK) @(negedge clk_adc);
            data_str = 0;
            repeat (4) @(negedge clk_adc);
        end
        repeat (20) @(negedge clk_adc);

        if (event_loss || event_beat != 0 || event_count != expected_events)
            $fatal(1, "incomplete production run events=%0d/%0d loss=%b beat=%0d",
                   event_count, expected_events, event_loss, event_beat);
        for (integer i = 0; i < chunks; i = i + 1) begin
            if (qualifies(expected_scores[start_window + i], threshold) && !event_seen[i])
                $fatal(1, "missing event for chunk: %0d", i + 1);
        end

        $display("PASS production SAIF chunks=%0d events=%0d start_window=%0d",
                 chunks, event_count, start_window);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout events=%0d/%0d active_mode=%0d pending=%b",
               event_count, expected_events, active_trigger_mode, mode_switch_pending);
    end
endmodule
