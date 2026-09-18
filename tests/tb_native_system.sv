`timescale 1ns/1ps
module tb_native_system;
    localparam MAX_WINDOWS = 4096;
    reg clk_adc = 0, clk_cnn = 0, rst = 1, data_str = 0;
    always #2 clk_adc = ~clk_adc;
    real phase = 0;
    initial begin
        void'($value$plusargs("PHASE=%f", phase));
        #(phase);
        forever #2.5 clk_cnn = ~clk_cnn;
    end
    reg [383:0] adc_data = 0;
    reg [383:0] adc_words [0:MAX_WINDOWS*64-1];
    reg [31:0] expected [0:MAX_WINDOWS-1];
    reg [31:0] threshold = 0;
    wire [31:0] score, event_score;
    wire [15:0] score_id, event_id;
    wire score_valid, event_valid, event_last, overflow, event_loss;
    wire [383:0] event_data;
    wire [23:0] event_timestamp;
    wire [5:0] event_offset;
    wire [3:0] active_mode;
    wire [31:0] dropped, ring_miss;
    integer overload = 0;
    bit allow_loss = 0;
    integer windows = 1096, gap = 0, received = 0, events = 0, event_beat = 0;
    integer expected_events = 0;
    integer seen [0:MAX_WINDOWS-1];
    bit event_seen [0:MAX_WINDOWS-1];
    string reference;
    reg event_ready = 1;
    // Independent real-valued checker for the fixed external configuration.
    function automatic bit qualifies(input reg [31:0] native_score,
                                     input reg [31:0] external_threshold);
        qualifies = ($itor($signed(native_score[20:0])) / 512.0) >
                    ($itor($signed(external_threshold)) / 16.0);
    endfunction
    AI_TRIGGER_TOP_TB_WRAP #(.DIRECT_ADC(1)) dut (
        .CLK_ADC(clk_adc), .ADC_SRC_CLK(clk_adc), .CLK_CNN(clk_cnn), .RST(rst),
        .DATA_STR(data_str), .ADC_DATA4_FLAT(adc_data), .TRIGGER_MODE(4'd2),
        .FORCE_TRIGGER(1'b0), .CNN_THRESH(threshold), .HL_THRESH(12'd100),
        .HILO_WINDOW(5'd5), .COINC_WINDOW(6'd3), .BIN_THR(4'd1),
        .CNN_OUT_DATA(score), .CNN_OUT_CHUNK_ID(score_id), .CNN_OUT_VALID(score_valid),
        .EVENT_VALID(event_valid), .EVENT_READY(event_ready), .EVENT_DATA(event_data),
        .EVENT_LAST(event_last), .EVENT_CHUNK_ID(event_id), .EVENT_TIMESTAMP(event_timestamp),
        .EVENT_TRIGGER_OFFSET(event_offset), .EVENT_SCORE(event_score),
        .ACTIVE_TRIGGER_MODE(active_mode), .EVENT_LOSS(event_loss),
        .DROPPED_TRIGGER_COUNT(dropped), .RING_MISS_COUNT(ring_miss), .CHUNK_OVERFLOW(overflow)
    );
    always @(posedge clk_cnn) if (!rst && score_valid) begin
        if (score_id < 1 || score_id > windows) $fatal(1, "unexpected score id %0d", score_id);
        if (seen[score_id-1]) $fatal(1, "duplicate score id %0d", score_id);
        if (score !== expected[score_id-1])
            $fatal(1, "score id=%0d expected=%h actual=%h", score_id, expected[score_id-1], score);
        seen[score_id-1] = 1;
        received++;
    end
    always @(posedge clk_adc) if (!rst) begin
        if (!allow_loss && (overflow || event_loss || dropped || ring_miss))
            $fatal(1, "loss at full-rate: overflow=%b loss=%b dropped=%0d ring=%0d scores=%0d", overflow,event_loss,dropped,ring_miss,received);
        if (event_valid && event_ready) begin
            if (event_id < 1 || event_id > windows) $fatal(1, "unexpected event id");
            if (!qualifies(expected[event_id-1], threshold))
                $fatal(1,"nonqualifying native score produced an event");
            if (event_seen[event_id-1]) $fatal(1,"duplicate event id=%0d",event_id);
            if (event_data !== adc_words[(event_id-1)*64+event_beat])
                $fatal(1, "raw waveform mismatch event=%0d beat=%0d", event_id,event_beat);
            if (event_score !== expected[event_id-1] || event_timestamp !== {8'd0,event_id} || event_offset !== 0)
                $fatal(1, "event metadata mismatch id=%0d",event_id);
            if (event_last !== (event_beat == 63)) $fatal(1, "event framing mismatch");
            if (event_beat == 63) begin events++; event_beat=0; event_seen[event_id-1]=1; end
            else event_beat++;
        end
    end
    initial begin
        if (!$value$plusargs("REFERENCE=%s",reference)) $fatal(1,"missing REFERENCE");
        void'($value$plusargs("WINDOWS=%d",windows));
        void'($value$plusargs("GAP=%d",gap));
        void'($value$plusargs("OVERLOAD=%d",overload));
        void'($value$plusargs("THRESHOLD=%h",threshold));
        if (windows < 1 || windows > MAX_WINDOWS) $fatal(1,"window count out of range");
        $readmemh({reference,"/adc.hex"},adc_words,0,windows*64-1);
        $readmemh({reference,"/all_expected.hex"},expected,0,windows-1);
        for (integer i=0;i<windows;i++) begin
            seen[i]=0; event_seen[i]=0;
            if (qualifies(expected[i], threshold)) expected_events++;
        end
        if (overload != 0) begin
            // Saturate finite event/trigger/core capacity with a stalled sink.
            // Returned work still has to match the original window exactly.
            allow_loss=1; threshold=32'h80000000; event_ready=0;
            repeat(40) @(negedge clk_adc); rst=0;
            repeat(40) @(negedge clk_adc);
            data_str=1; repeat(64) @(negedge clk_adc); data_str=0;
            wait(active_mode==2); repeat(20) @(negedge clk_adc);
            for (integer i=0;i<windows*64;i++) begin
                adc_data=adc_words[i]; data_str=1; @(negedge clk_adc);
            end
            data_str=0;
            repeat(200) @(negedge clk_adc);
            if (!event_loss) $fatal(1,"overload did not report loss");
            event_ready=1;
            repeat(15000) @(negedge clk_adc);
            if (event_valid || score_valid || event_beat!=0) $fatal(1,"overload failed to drain complete events");
            $display("PASS native overload accepted_scores=%0d complete_events=%0d",received,events);
            rst=1;
            repeat(40) @(negedge clk_adc);
            allow_loss=0; threshold=0; adc_data=0;
            received=0; events=0; event_beat=0; expected_events=0;
            for (integer i=0;i<windows;i++) begin
                seen[i]=0; event_seen[i]=0;
                if ($signed(expected[i][20:0])>0) expected_events++;
            end
        end
        repeat(40) @(negedge clk_adc);
        rst=0;
        repeat(40) @(negedge clk_adc);
        // Complete an ignored startup chunk to leave Reset Hold Mode.
        data_str=1;
        repeat(64) @(negedge clk_adc);
        data_str=0;
        wait(active_mode == 2);
        repeat(20) @(negedge clk_adc);
        for (integer i=0;i<windows*64;i++) begin
            adc_data=adc_words[i]; data_str=1;
            @(negedge clk_adc);
            if (gap != 0 && i % 17 == 3) begin
                data_str=0;
                repeat(gap) @(negedge clk_adc);
            end
        end
        data_str=0;
        wait(received == windows && events == expected_events);
        repeat(200) @(negedge clk_adc);
        if (received != windows || events != expected_events || event_beat != 0)
            $fatal(1,"incorrect completion counts");
        $display("PASS native system windows=%0d events=%0d gap=%0d phase=%0f",received,events,gap,phase);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"timeout scores=%0d/%0d events=%0d/%0d",received,windows,events,expected_events);
    end
endmodule
