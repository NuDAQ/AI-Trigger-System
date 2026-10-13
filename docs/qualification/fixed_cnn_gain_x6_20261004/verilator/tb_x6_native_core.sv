`timescale 1ns/1ps
module tb_x6_native_core;
    reg clk=0, rst_n=0, start=0, valid=0;
    always #2.5 clk=~clk;
    reg [511:0] data=0;
    wire ready, out_valid, done, ap_ready, idle;
    wire [31:0] score;
    reg [511:0] words [0:35071];
    reg [31:0] expected [0:1095];
    integer windows=1096, received=0;
    string reference;
    bit start_accepted=0;
    cnn_core dut(.ap_clk(clk), .ap_rst_n(rst_n), .ap_start(start),
        .ap_done(done), .ap_ready(ap_ready), .ap_idle(idle),
        .waveform_TDATA(data), .waveform_TVALID(valid), .waveform_TREADY(ready),
        .layer12_out_TDATA(score), .layer12_out_TVALID(out_valid), .layer12_out_TREADY(1'b1));
    always @(posedge clk) if(rst_n) begin
        if(start && ap_ready) start_accepted=1;
        if(out_valid) begin
            if(received>=windows || score!==expected[received])
                $fatal(1,"native score window=%0d got=%h expected=%h", received, score, expected[received]);
            received++;
        end
    end
    initial begin
        if(!$value$plusargs("REFERENCE=%s",reference)) $fatal(1,"missing reference");
        void'($value$plusargs("WINDOWS=%d",windows));
        $readmemh({reference,"/all_input.hex"},words,0,windows*32-1);
        $readmemh({reference,"/all_expected.hex"},expected,0,windows-1);
        repeat(10) @(negedge clk);
        rst_n=1;
        for(integer frame=0;frame<windows;frame++) begin
            start_accepted=0; start=1;
            for(integer word_idx=0;word_idx<32;word_idx++) begin
                data=words[frame*32+word_idx]; valid=1;
                do @(posedge clk); while(!ready);
                @(negedge clk);
            end
            valid=0;
            wait(start_accepted);
            @(negedge clk); start=0;
            wait(received==frame+1);
            repeat(2) @(negedge clk);
        end
        repeat(10) @(negedge clk);
        $display("PASS Verilator native core: %0d exact scores",received);
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout received=%0d",received); end
endmodule
