# This script was generated automatically by bender.
set ROOT "/home/work1/Works/AI-Trigger-System"
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_compute_output_buffer_1d_array_array_ap_fixed_17_9_5_3_0_7u_config4_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_conv_2d_cl_array_ap_fixed_1u_array_ap_fixed_17_9_5_3_0_7u_config4_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_dense_array_ap_fixed_42u_array_ap_fixed_17_9_5_3_0_1u_config10_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_dense_array_array_ap_fixed_17_9_5_3_0_1u_config10_Pipeline_DataPrepare.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_dense_latency_ap_fixed_12_6_5_3_0_ap_fixed_17_9_5_3_0_config4_mult_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_dense_latency_wrapper_ap_fixed_ap_fixed_17_9_5_3_0_config10_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w112_d168_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w112_d336_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w119_d336_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w12_d1024_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w3072_d4_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_fifo_w672_d28_A.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe_sequential_init.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_hls_deadlock_detection_unit.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_hls_deadlock_idx0_monitor.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_6s_18_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_7ns_19_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_7s_19_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_8ns_20_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_8s_20_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_9ns_20_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_12s_9s_20_1_0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_10ns_24_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_5ns_21_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_5s_21_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_6ns_22_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_6s_22_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_7ns_23_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_7s_23_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_8ns_24_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_8s_24_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_mul_16s_9ns_24_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_pooling2d_cl_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_7u_config6_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_regslice_both.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_relu_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_7u_relu_config5_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_repack_stream_array_ap_fixed_256u_array_ap_fixed_12_6_5_3_0_1u_1024_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_repack_stream_array_ap_fixed_256u_array_ap_fixed_12_6_5_3_0_1u_1024_s_in_databkb.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_repack_stream_array_ap_fixed_42u_array_ap_fixed_16_6_5_3_0_42u_1176_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_repack_stream_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_42u_1176_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_repack_stream_array_array_ap_fixed_1u_1024_Pipeline_VITIS_LOOP_254_4.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_shift_line_buffer_array_ap_fixed_16_6_5_3_0_7u_config6_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_sparsemux_9_2_12_1_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_conv_2d_cl_array_ap_fixed_1u_array_ap_fixed_17_9_5_3_0_7u_config4_U0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_dense_array_ap_fixed_42u_array_ap_fixed_17_9_5_3_0_1u_config10_U0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_pooling2d_cl_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_7u_config6dEe.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_relu_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_7u_relu_config5_U0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_repack_stream_array_ap_fixed_256u_array_ap_fixed_12_6_5_3_0_1u_1024cud.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_repack_stream_array_ap_fixed_42u_array_ap_fixed_16_6_5_3_0_42u_1176eOg.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_start_for_repack_stream_array_ap_fixed_7u_array_ap_fixed_16_6_5_3_0_42u_1176_U0.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_transpose_array_ap_fixed_4u_array_ap_fixed_12_6_5_3_0_256u_config2_s.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_transpose_array_array_ap_fixed_256u_config2_Pipeline_VITIS_LOOP_16_1.v \
    $ROOT/.bender/git/checkouts/cnn-core-338ad22ef78c637b/cnn_core_project/cnn_core_prj/solution1/impl/verilog/cnn_core_transpose_array_array_ap_fixed_256u_config2_Pipeline_VITIS_LOOP_25_3.v \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/rtl/cnn_core_wrapper_top.v \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/PreTrigger/ila_pkg.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/PreTrigger/Mult_to_bin.vhd \
    $ROOT/HDL/PreTrigger/PRE_TRIGGER_PKG.vhd \
    $ROOT/HDL/PreTrigger/Pre_trigger.vhd \
    $ROOT/HDL/PreTrigger/Pre_trigger_1ch.vhd \
    $ROOT/HDL/PreTrigger/ila_pkg.vhd \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/HiLoPath/CNN_FIFO_CONNECTOR.vhd \
    $ROOT/HDL/HiLoPath/HILO_PATH_WRAPPER.vhd \
    $ROOT/HDL/HiLoPath/TEMP_SYS_TOP.vhd \
    $ROOT/HDL/HiLoPath/sim/TEMP_SYS_TOP_TB_WRAP.vhd \
]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SYNTHESIS \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SYNTHESIS \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset -simset]

