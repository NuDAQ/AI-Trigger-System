#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "Cleaning previous simulation artifacts..."
rm -rf work/ *.fst

echo "----------------------------------------"
echo " Step 1: Analyzing Dependencies"
echo "----------------------------------------"
# 1. Packages (Must be compiled first)
nvc -a PRE_TRIGGER_PKG.vhd
nvc -a ila_pkg.vhd

# 2. Sub-components (Leaf nodes)
nvc -a Mult_to_bin.vhd
nvc -a Pre_trigger_1ch.vhd

# 3. Top-level assembly
nvc -a Pre_trigger.vhd

# 4. Testbenches (Directory paths required)
nvc -a sim/tb_pre_trigger_1ch.vhd
nvc -a sim/tb_pre_trigger.vhd

echo "----------------------------------------"
echo " Step 2: Elaborating Testbenches"
echo "----------------------------------------"
nvc -e tb_pre_trigger_1ch
nvc -e tb_pre_trigger

echo "----------------------------------------"
echo " Step 3: Running Simulations"
echo "----------------------------------------"
echo "Running Single-Channel Testbench..."
nvc -r tb_pre_trigger_1ch --wave=wave_1ch.fst

echo "Running Top-Level Testbench..."
nvc -r tb_pre_trigger --wave=wave_top.fst

echo "----------------------------------------"
echo " Simulation Complete. Waveforms saved as .fst files."