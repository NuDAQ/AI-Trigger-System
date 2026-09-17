`timescale 1ns/1ps
module tb_native_modes;
    reg clk_adc=0, clk_cnn=0, rst=1, data_str=0, force_trigger=0;
    always #2 clk_adc=~clk_adc;
    always #2.5 clk_cnn=~clk_cnn;
    reg [3:0] mode=0;
    reg [383:0] adc_data=0;
    reg [383:0] waveform [0:191];
    reg [31:0] expected [0:0];
    wire event_valid, event_last, event_loss, score_valid;
    wire [383:0] event_data;
    wire [23:0] timestamp;
    wire [5:0] offset;
    wire [31:0] event_score, score, dropped, ring_miss;
    wire [3:0] active_mode;
    integer first_timestamp=1;
    integer event_beats=0, score_count=0, expected_beats=0;
    reg ready=1;
    string reference;
    AI_TRIGGER_TOP_TB_WRAP #(.DIRECT_ADC(1)) dut (
        .CLK_ADC(clk_adc), .ADC_SRC_CLK(clk_adc), .CLK_CNN(clk_cnn), .RST(rst),
        .DATA_STR(data_str), .ADC_DATA4_FLAT(adc_data), .TRIGGER_MODE(mode),
        .FORCE_TRIGGER(force_trigger), .CNN_THRESH(32'h00100000), .HL_THRESH(12'd100),
        .HILO_WINDOW(5'd5), .COINC_WINDOW(6'd3), .BIN_THR(4'd1),
        .CNN_OUT_DATA(score), .CNN_OUT_VALID(score_valid),
        .EVENT_VALID(event_valid), .EVENT_READY(ready), .EVENT_DATA(event_data),
        .EVENT_LAST(event_last), .EVENT_TIMESTAMP(timestamp),
        .EVENT_TRIGGER_OFFSET(offset), .EVENT_SCORE(event_score),
        .ACTIVE_TRIGGER_MODE(active_mode), .EVENT_LOSS(event_loss),
        .DROPPED_TRIGGER_COUNT(dropped), .RING_MISS_COUNT(ring_miss)
    );
    always @(posedge clk_cnn) if (!rst && score_valid) begin
        if (mode != 4 || score_count != 0 || score !== expected[0])
            $fatal(1,"gated CNN score mismatch mode=%0d expected=%h actual=%h",mode,expected[0],score);
        score_count++;
    end
    always @(posedge clk_adc) if (!rst) begin
        if (event_loss || dropped || ring_miss) $fatal(1,"mode %0d lost an event",mode);
        if (event_valid && ready) begin
            if (event_beats >= expected_beats) $fatal(1,"extra event mode=%0d",mode);
            if (event_data !== waveform[(mode==0 ? 64 : 38)+event_beats])
                $fatal(1,"mode %0d raw window mismatch at beat %0d",mode,event_beats);
            if (timestamp !== (mode==0 ? first_timestamp+event_beats/64 : 1) || offset !== (mode==0 ? 0 : 5))
                $fatal(1,"mode %0d anchor mismatch time=%0d offset=%0d",mode,timestamp,offset);
            if (event_score !== (mode==4 ? expected[0] : 0)) $fatal(1,"event score mismatch");
            if (event_last !== (event_beats%64==63)) $fatal(1,"partial event");
            event_beats++;
        end
    end
    task automatic run_mode(input integer selected);
        rst=1; data_str=0; force_trigger=0; ready=1;
        mode=selected;
        repeat(40) @(negedge clk_adc);
        event_beats=0; score_count=0; expected_beats=(selected==0 ? 128 : 64);
        rst=0;
        repeat(40) @(negedge clk_adc);
        for (integer i=0;i<192;i++) begin
            adc_data=waveform[i]; data_str=1;
            force_trigger=(selected==1 && i==69);
            // Short event-sink stalls must preserve all eight raw channels.
            ready=(i%11!=2);
            @(negedge clk_adc);
        end
        data_str=0; force_trigger=0; ready=1;
        wait(event_beats==expected_beats);
        repeat(200) @(negedge clk_adc);
        if ((selected==4 && score_count!=1) || (selected!=4 && score_count!=0))
            $fatal(1,"unexpected CNN work in mode %0d",selected);
        $display("PASS native mode=%0d events=%0d CNN=%0d",selected,event_beats/64,score_count);
    endtask
    initial begin
        if (!$value$plusargs("REFERENCE=%s",reference)) $fatal(1,"missing reference");
        $readmemh({reference,"/gated/adc.hex"},waveform);
        $readmemh({reference,"/gated/all_expected.hex"},expected);
        run_mode(0); run_mode(1); run_mode(3); run_mode(4);
        // Switch from gated AI to Capture-All without resetting waveform
        // history; the request applies only at the next complete chunk.
        @(negedge clk_adc); mode=0; expected_beats=0; event_beats=0; score_count=0;
        for (integer i=0;i<64;i++) begin
            adc_data=waveform[i]; data_str=1; @(negedge clk_adc);
        end
        data_str=0;
        wait(active_mode==0);
        repeat(20) @(negedge clk_adc);
        first_timestamp=4; expected_beats=128;
        for (integer i=64;i<192;i++) begin
            adc_data=waveform[i]; data_str=1; @(negedge clk_adc);
        end
        data_str=0;
        wait(event_beats==128);
        repeat(200) @(negedge clk_adc);
        if (score_count!=0) $fatal(1,"stale CNN work after mode switch");
        $display("PASS native runtime mode switch gated AI to Capture-All");
        $display("PASS native modes complete");
        $finish;
    end
    initial begin #100000; $fatal(1,"mode timeout mode=%0d events=%0d CNN=%0d",mode,event_beats/64,score_count); end
endmodule
