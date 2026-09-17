`timescale 1ns/1ps
module tb_native_lane;
    reg clk_adc=0, clk_cnn=0, rst=1, wr_en=0, lane_ready=0;
    always #2 clk_adc=~clk_adc;
    always #2.5 clk_cnn=~clk_cnn;
    reg [255:0] batch=0;
    reg [15:0] chunk=0;
    reg [23:0] timestamp=0;
    reg [31:0] threshold=0;
    reg [511:0] input_words [0:511];
    reg [31:0] expected [0:15];
    wire busy, pending_work, valid;
    wire [31:0] score, result_threshold;
    wire [15:0] result_chunk;
    wire [23:0] result_timestamp;
    wire [5:0] result_start, result_trigger;
    string reference;
    CNN_CORE_LANE #(.DEBUG_EVENTS(0)) dut (
        .CLK_ADC(clk_adc),.CLK_CNN(clk_cnn),.RST_ASYNC(rst),.RST_ADC(rst),.RST_CNN(rst),
        .WR_EN(wr_en),.BATCH_DATA(batch),.CHUNK_ID(chunk),.CHUNK_TIMESTAMP(timestamp),
        .WORK_START_OFFSET(6'd17),.WORK_TRIGGER_OFFSET(6'd48),.CNN_THRESH(threshold),
        .CHUNK_BUSY(busy),.WORK_PENDING(pending_work),.LANE_SCORE(score),
        .LANE_CHUNK_ID(result_chunk),.LANE_TIMESTAMP(result_timestamp),
        .LANE_START_OFFSET(result_start),.LANE_TRIGGER_OFFSET(result_trigger),
        .LANE_THRESH(result_threshold),.LANE_VALID(valid),.LANE_READY(lane_ready)
    );
    task automatic reset_lane;
        @(negedge clk_adc); rst=1; wr_en=0; lane_ready=0;
        repeat(40) @(negedge clk_adc);
        rst=0;
        repeat(40) @(negedge clk_adc);
        if (pending_work || valid || busy) $fatal(1,"reset did not abort native work and metadata");
    endtask
    task automatic feed(input integer frame, input integer beats, input integer gaps);
        wait(!busy);
        @(negedge clk_adc);
        chunk=frame+100; timestamp=frame+1000; threshold=frame+500;
        for (integer b=0;b<beats;b++) begin
            batch=input_words[frame*32+b/2] >> (256*(b%2));
            wr_en=1;
            @(negedge clk_adc);
            threshold=32'hdeadbeef;
            if (gaps && b%7==3) begin
                wr_en=0;
                repeat(9) @(negedge clk_adc);
            end
        end
        wr_en=0;
    endtask
    task automatic consume(input integer frame);
        wait(valid);
        repeat(23) begin
            @(negedge clk_cnn);
            if (!valid || score !== expected[frame] || result_chunk !== frame+100 ||
                result_timestamp !== frame+1000 || result_threshold !== frame+500 ||
                result_start !== 17 || result_trigger !== 48)
                $fatal(1,"native result or immutable metadata changed under backpressure frame=%0d",frame);
        end
        lane_ready=1;
        @(negedge clk_cnn);
        lane_ready=0;
        repeat(10) @(negedge clk_cnn);
        if (valid || pending_work) $fatal(1,"native result failed to retire exactly once");
    endtask
    initial begin
        if (!$value$plusargs("REFERENCE=%s",reference)) $fatal(1,"missing reference");
        $readmemh({reference,"/all_input.hex"},input_words,0,511);
        $readmemh({reference,"/all_expected.hex"},expected,0,15);
        reset_lane();
        feed(0,17,0); // reset while acquiring/streaming a partial window
        reset_lane(); feed(1,64,1); consume(1);
        feed(2,64,0); // reset after input completion, before result
        reset_lane(); feed(3,64,0); consume(3);
        feed(4,64,0); wait(valid); // reset with an unconsumed native result
        reset_lane(); feed(5,64,1); consume(5);
        $display("PASS native lane input/compute/output resets, gaps and held results");
        $finish;
    end
    initial begin #100000; $fatal(1,"native lane timeout"); end
endmodule
