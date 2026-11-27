#!/bin/bash
# Run every unit testbench with Icarus Verilog. Usage: bash fpga/sim/unit/run_all.sh  (from anywhere)
set -e
U="$(cd "$(dirname "$0")" && pwd)"; F="$(cd "$U/../.." && pwd)"
INC="-I$F/rtl/gen -I$F/rtl/video -I$F/rtl/shared"
B="$F/build/unit"; mkdir -p "$B"
python3 "$U/gen_vectors.py" > /dev/null
cd "$U"
iverilog $INC -o "$B/tb_lfsr.vvp" tb_lfsr.v && vvp -n "$B/tb_lfsr.vvp" | grep -E "PASS|FAIL|step"
iverilog $INC -o "$B/tb_vga_timing.vvp" tb_vga_timing.v "$F/rtl/video/vga_timing.v" && vvp -n "$B/tb_vga_timing.vvp" | grep -E "PASS|FAIL|expected|slots|pixels"
iverilog $INC -o "$B/tb_input_ctrl.vvp" tb_input_ctrl.v "$F/rtl/core/input_ctrl.v" && vvp -n "$B/tb_input_ctrl.vvp" | grep -E "PASS|FAIL|press|edges"
iverilog $INC -o "$B/tb_card_deck.vvp" tb_card_deck.v "$F/rtl/shared/card_deck.v" && vvp -n "$B/tb_card_deck.vvp" | grep -E "PASS|FAIL|perm|close"
iverilog $INC -o "$B/tb_stage3_jump.vvp" tb_stage3_jump.v "$F/rtl/stage3/stage3.v" && vvp -n "$B/tb_stage3_jump.vvp" | grep -E "PASS|FAIL|apex|ground"
cd "$F/mem"     # stage2 reads s2_walk.mem from the working directory
iverilog $INC -o "$B/tb_stage2_eval.vvp" "$U/tb_stage2_eval.v" "$F/rtl/stage2/stage2.v" "$F/rtl/shared/card_deck.v" "$F/rtl/shared/sprite_anim.v" \
    && vvp -n "$B/tb_stage2_eval.vvp" | grep -E "PASS|FAIL|code|build|chip"
