`timescale 1ns / 1ps

module tb_real_noise_scan_pacer;
    real_noise_scan_pacer_if pacer();
    bit released;

    initial begin
        released = 0;
        pacer.note_chunk_sent(16'd7);
        fork
            begin
                pacer.wait_until_safe(16'd7);
                released = 1;
            end
        join_none

        #1;
        assert (!released) else $fatal(1, "chunk released before its score");

        pacer.note_score(16'd7, 1'b1);
        #1;
        assert (!released) else $fatal(1, "triggered chunk released before event completion");

        pacer.note_event_complete(16'd8);
        #1;
        assert (!released) else $fatal(1, "mismatched event released the active chunk");

        pacer.note_event_complete(16'd7);
        #1;
        assert (released) else $fatal(1, "matching event did not release triggered chunk");

        released = 0;
        pacer.note_chunk_sent(16'd8);
        fork
            begin
                pacer.wait_until_safe(16'd8);
                released = 1;
            end
        join_none

        #1;
        pacer.note_score(16'd8, 1'b0);
        #1;
        assert (released) else $fatal(1, "non-triggered chunk did not release after its score");

        $display("tb_real_noise_scan_pacer passed");
        $finish;
    end
endmodule
