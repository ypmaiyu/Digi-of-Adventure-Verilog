#!/bin/sh
# Builds the Verilator whole-system model (run from fpga/). Needs verilator >= 5.
set -e
cd "$(dirname "$0")/../.."
verilator --cc --exe --build -O3 -j 4 -Wno-fatal -Wno-WIDTH -Wno-BLKSEQ -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
  --x-assign fast --x-initial fast \
  -Irtl/gen -Irtl/video -Irtl/shared --top-module nexys_a7_top \
  -GDEBOUNCE=1000 \
  rtl/top/nexys_a7_top.v rtl/flow/*.v rtl/stage1/*.v rtl/stage2/*.v rtl/stage3/*.v rtl/shared/*.v rtl/core/*.v rtl/video/*.v \
  $(pwd)/sim/verilator/sim_main.cpp --Mdir build/verilator -o Vnexys_a7_top
echo "built build/verilator/Vnexys_a7_top"
