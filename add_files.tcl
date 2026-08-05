# This script was generated automatically by bender.
set ROOT "/Users/albert/Library/Mobile Documents/com~apple~CloudDocs/Works/UC_Irvine_Group/AI-Trigger-System"

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
    $ROOT/.bender/git/checkouts/hilo-trigger-c9008b4370da5322/hw/rtl/PRE_TRIGGER_PKG.vhd \
    $ROOT/.bender/git/checkouts/hilo-trigger-c9008b4370da5322/hw/rtl/Mult_to_bin.vhd \
    $ROOT/.bender/git/checkouts/hilo-trigger-c9008b4370da5322/hw/rtl/Pre_trigger_1ch.vhd \
    $ROOT/.bender/git/checkouts/hilo-trigger-c9008b4370da5322/hw/rtl/Pre_trigger.vhd \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/hilo-trigger-c9008b4370da5322/hw/constraints/pre_trigger.xdc \
]

add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/rtl/AI_TRIGGER_PKG.vhd \
    $ROOT/HDL/rtl/RESET_SYNC.vhd \
    $ROOT/HDL/rtl/TRIGGER_MODE_CTRL.vhd \
    $ROOT/HDL/rtl/HOUSEKEEPING_TRIGGER_CTRL.vhd \
    $ROOT/HDL/rtl/HILO_INPUT_ADAPTER.vhd \
    $ROOT/HDL/rtl/HILO_TRIGGER_CTRL.vhd \
    $ROOT/HDL/rtl/GATED_CNN_READER.vhd \
    $ROOT/HDL/rtl/TRIGGER_DECISION.vhd \
    $ROOT/HDL/rtl/ADC_INPUT_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/CHUNK_ID_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/TRIGGER_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/WAVEFORM_RING_BUFFER.vhd \
    $ROOT/HDL/rtl/RING_READ_ARBITER.vhd \
    $ROOT/HDL/rtl/EVENT_RECORDER.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_CTRL.vhd \
    $ROOT/HDL/rtl/EVENT_OUTPUT_FIFO.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_PATH.vhd \
    $ROOT/HDL/rtl/MULTIMODE_EVENT_PATH.vhd \
    $ROOT/HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd \
    $ROOT/HDL/rtl/CNN_CORE_LANE.vhd \
    $ROOT/HDL/rtl/CNN_RESULT_ARBITER.vhd \
    $ROOT/HDL/rtl/AI_TRIGGER_CORE.vhd \
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

