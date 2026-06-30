# This script was generated automatically by bender.
set ROOT "/home/work1/Works/AI-Trigger-System"

add_files -norecurse -fileset [current_fileset] [list \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_dense_wide_stream_array_array_ap_fixed_1u_config9_Pipeline_DenseWideMain.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_dense_wide_stream_array_array_ap_fixed_22_11_5_3_0_1u_config9_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_fifo_w252_d4_S.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_fifo_w420_d4_S.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_fifo_w448_d4_S.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_first_conv_2row_4lane_temporal_wide_cl_array_array_ap_fixed_28u_config4_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe_sequential_init.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mac_muladd_9s_7s_16s_16_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mac_muladd_9s_7s_16s_17_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_maxpool2d_wide_nonoverlap_cl_array_array_ap_fixed_28u_config6_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_5ns_13_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_5ns_14_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_6ns_14_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_6ns_15_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_6s_15_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_9s_7s_16_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_regslice_both.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_relu_array_ap_fixed_28u_array_ap_ufixed_15_5_5_3_0_28u_relu_config5_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_sparsemux_2353_11_7_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_sparsemux_9_2_9_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_dense_wide_stream_array_array_ap_fixed_22_11_5_3_0_1u_config9_U0.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_maxpool2d_wide_nonoverlap_cl_array_array_ap_fixed_28u_config6_U0.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_relu_array_ap_fixed_28u_array_ap_ufixed_15_5_5_3_0_28u_relu_config5bkb.v \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/rtl/cnn_core_wrapper_top.v \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/sim/tb_stream.sv \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/rtl/AI_TRIGGER_PKG.vhd \
    $ROOT/HDL/rtl/RESET_SYNC.vhd \
    $ROOT/HDL/rtl/TRIGGER_DECISION.vhd \
    $ROOT/HDL/rtl/CHUNK_ID_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/TRIGGER_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/WAVEFORM_RING_BUFFER.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_CTRL.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_PATH.vhd \
    $ROOT/HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd \
    $ROOT/HDL/rtl/CNN_CORE_LANE.vhd \
    $ROOT/HDL/rtl/AI_TRIGGER_TOP.vhd \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/sim/tb_ai_trigger_top.sv \
]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SIMULATION \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SIMULATION \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset -simset]

