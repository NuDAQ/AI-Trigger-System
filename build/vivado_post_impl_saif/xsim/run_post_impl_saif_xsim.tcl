run 2.0 us
open_saif {/home/work1/Works/AI-Trigger-System/build/vivado_post_impl_saif/activity/ai_trigger_post_impl.saif}
log_saif [get_objects -r /tb_AI_TRIGGER_TOP/dut/*]
run all
close_saif
quit
