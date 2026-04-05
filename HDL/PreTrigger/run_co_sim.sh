#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Move into the sim directory to contain all generated artifacts
cd sim

echo "Cleaning previous simulation artifacts in /sim..."
rm -rf work/ *.fst

echo "----------------------------------------"
echo " Step 1: Analyzing Dependencies"
echo "----------------------------------------"
# 1. Packages (Note: ila_pkg removed, paths point to parent directory)
nvc -a ../PRE_TRIGGER_PKG.vhd

# 2. Sub-components
nvc -a ../Mult_to_bin.vhd
nvc -a ../Pre_trigger_1ch.vhd

# 3. Top-level assembly
nvc -a ../Pre_trigger.vhd

# 4. Testbenches (Now in current directory)
nvc -a tb_pre_trigger_1ch.vhd
nvc -a tb_pre_trigger.vhd
nvc -a tb_pre_trigger_cosim.vhd

echo "----------------------------------------"
echo " Step 2: Elaborating Testbenches"
echo "----------------------------------------"
nvc -e tb_pre_trigger_1ch
nvc -e tb_pre_trigger
nvc -e tb_pre_trigger_cosim

echo "----------------------------------------"
echo " Step 3: Running Simulations"
echo "----------------------------------------"
echo "Running Single-Channel Testbench..."
nvc -r tb_pre_trigger_1ch --wave=wave_1ch.fst

echo "Running Top-Level Testbench..."
nvc -r tb_pre_trigger --wave=wave_top.fst

echo "Running Data-Driven Co-Simulation Testbench..."
nvc -r tb_pre_trigger_cosim --wave=wave_cosim.fst

echo "----------------------------------------"
echo " Simulation Complete. Artifacts contained in /sim."
echo " Co-simulation outputs written to ../../../analysis/PreTrigger/"

# Return to root
cd ..