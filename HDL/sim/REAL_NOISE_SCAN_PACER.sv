`timescale 1ns / 1ps

// Simulation-only single-in-flight guard for paced score scans.
interface real_noise_scan_pacer_if;
    bit          active = 0;
    bit [15:0]   active_chunk_id = 0;
    bit          score_seen = 0;
    bit          score_triggered = 0;
    bit          event_complete = 0;

    task automatic note_chunk_sent(input bit [15:0] chunk_id);
        if (active)
            $fatal(1, "scan pacer accepted chunk %0d while chunk %0d is active",
                   chunk_id, active_chunk_id);
        active = 1;
        active_chunk_id = chunk_id;
        score_seen = 0;
        score_triggered = 0;
        event_complete = 0;
    endtask

    task automatic note_score(
        input bit [15:0] chunk_id,
        input bit        triggered
    );
        if (!active || chunk_id != active_chunk_id)
            $fatal(1, "scan pacer score chunk %0d does not match active chunk %0d",
                   chunk_id, active_chunk_id);
        score_triggered = triggered;
        score_seen = 1;
    endtask

    task automatic note_event_complete(input bit [15:0] chunk_id);
        if (active && chunk_id == active_chunk_id)
            event_complete = 1;
    endtask

    task automatic wait_until_safe(input bit [15:0] chunk_id);
        if (!active || chunk_id != active_chunk_id)
            $fatal(1, "scan pacer wait chunk %0d does not match active chunk %0d",
                   chunk_id, active_chunk_id);
        wait (score_seen && (!score_triggered || event_complete));
        active = 0;
    endtask
endinterface
