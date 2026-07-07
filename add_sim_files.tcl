# This script was generated automatically by bender.
set ROOT "/Users/albert/Library/Mobile Documents/com~apple~CloudDocs/Works/UC_Irvine_Group/AI-Trigger-System"

# Package(cnn-core-wrapper) Target(*)
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/rtl/cnn_core_wrapper_top.v \
]

# Package(cnn-core-wrapper) Target(simulation)
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/cnn-core-wrapper-85593ce6023e5d56/hw/sim/tb_stream.sv \
]

# Package(ai-trigger-system) Target(*)
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/rtl/AI_TRIGGER_PKG.vhd \
    $ROOT/HDL/rtl/RESET_SYNC.vhd \
    $ROOT/HDL/rtl/TRIGGER_DECISION.vhd \
    $ROOT/HDL/rtl/ADC_INPUT_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/CHUNK_ID_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/TRIGGER_CDC_FIFO.vhd \
    $ROOT/HDL/rtl/WAVEFORM_RING_BUFFER.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_CTRL.vhd \
    $ROOT/HDL/rtl/EVENT_OUTPUT_FIFO.vhd \
    $ROOT/HDL/rtl/EVENT_CAPTURE_PATH.vhd \
    $ROOT/HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd \
    $ROOT/HDL/rtl/CNN_CORE_LANE.vhd \
    $ROOT/HDL/rtl/AI_TRIGGER_CORE.vhd \
    $ROOT/HDL/rtl/AI_TRIGGER_TOP.vhd \
]

# Package(ai-trigger-system) Target(simulation)
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd \
]

# Package(ai-trigger-system) Target(simulation)
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/HDL/sim/tb_ai_trigger_top.sv \
]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SIM \
    TARGET_SIMULATION \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SIM \
    TARGET_SIMULATION \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset -simset]

