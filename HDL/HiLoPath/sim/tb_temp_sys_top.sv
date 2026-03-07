`timescale 1ns / 10ps

import pre_trigger_pkg::*;

module tb_TEMP_SYS_TOP;

    parameter FAST_CLK_PERIOD = 16.0; 
    parameter SLOW_CLK_PERIOD = 5.0;  

    reg  clk_fast = 0;
    reg  clk_slow = 0;
    reg  sys_rst;
    reg  data_str;
    
    reg [11:0] adc_data_tb [0:7][0:15];
    
    wire        l0_pre_trig;
    wire [31:0] cnn_out_data;
    wire        cnn_out_valid;
    reg         cnn_out_ready;

    TEMP_SYS_TOP uut (
        .CLK_FAST      (clk_fast),
        .CLK_SLOW      (clk_slow),
        .SYS_RST       (sys_rst),
        .DATA_STR      (data_str),
        .ADC_DATA8     (adc_data_tb),
        .L0_PRE_TRIG   (l0_pre_trig),
        .CNN_OUT_DATA  (cnn_out_data),
        .CNN_OUT_VALID (cnn_out_valid),
        .CNN_OUT_READY (cnn_out_ready)
    );

    always #(FAST_CLK_PERIOD/2.0) clk_fast = ~clk_fast;
    always #(SLOW_CLK_PERIOD/2.0) clk_slow = ~clk_slow;

    task clear_adc();
        integer c, s;
        for (c = 0; c < 8; c = c + 1) begin
            for (s = 0; s < 15; s = s + 1) begin
                adc_data_tb[c][s] = 12'h000;
            end
        end
    endtask

    initial begin
        sys_rst       = 1;
        data_str      = 0;
        cnn_out_ready = 1;
        clear_adc();

        repeat(20) @(posedge clk_fast);
        sys_rst = 0;
        repeat(10) @(posedge clk_fast);

        data_str = 1;
        repeat(50) @(posedge clk_fast);
        
        // Inject spike over the threshold (0x800)
        @(posedge clk_fast);
        adc_data_tb[0][5] <= 12'hA00;
        adc_data_tb[1][5] <= 12'hA00;
        adc_data_tb[2][5] <= 12'hA00;
        
        @(posedge clk_fast);
        clear_adc();
        
        // Await CNN completion
        fork
            begin
                wait(cnn_out_valid == 1);
            end
            begin
                #50000;
                $display("ERROR: Timeout.");
                $finish;
            end
        join_any

        repeat(20) @(posedge clk_slow);
        $finish;
    end

endmodule