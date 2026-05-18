# This script was generated automatically by bender.
set ROOT "/home/work1/Works/AI-Trigger-System"

add_files -norecurse -fileset [current_fileset] [list \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_dense_wide_stream_array_array_ap_fixed_1u_config7_Pipeline_DenseWideMain.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_dense_wide_stream_array_array_ap_fixed_9_5_5_3_0_1u_config7_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_fifo_w252_d4_S.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_fifo_w448_d4_S.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_first_conv_4lane_temporal_wide_cl_array_array_ap_fixed_28u_config3_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_flow_control_loop_pipe_sequential_init.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_maxpool2d_wide_nonoverlap_cl_array_array_ap_fixed_28u_config5_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_12s_5ns_15_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_mul_16s_6s_20_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_regslice_both.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_relu_array_ap_fixed_28u_array_ap_fixed_16_6_5_3_0_28u_relu_config4_s.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_sparsemux_11_3_12_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_sparsemux_2353_11_6_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_sparsemux_9_2_16_1_1.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_dense_wide_stream_array_array_ap_fixed_9_5_5_3_0_1u_config7_U0.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_maxpool2d_wide_nonoverlap_cl_array_array_ap_fixed_28u_config5_U0.v \
    /home/work1/Works/CNN-Core-Generator/hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog/cnn_core_start_for_relu_array_ap_fixed_28u_array_ap_fixed_16_6_5_3_0_28u_relu_config4_U0.v \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/rtl/cnn_core_wrapper_top.v \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/01_clocks.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/02_io_delays.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/03_clock_groups.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/04_uncertainty.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/05_multicycle_falsepaths.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/10_io_standards.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/20_pins.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/21_diff_pairs.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/22_interface_adc.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/23_interface_spi.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/24_interface_axi.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/30_timing_extras.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/40_debug_ila.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/50_power_thermal.xdc \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/xdc/99_local_override.xdc \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/rtl/AI_TRIGGER_PKG.vhd \
    $ROOT/HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd \
    $ROOT/HDL/rtl/CNN_CORE_LANE.vhd \
    $ROOT/HDL/rtl/AI_TRIGGER_TOP.vhd \
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

