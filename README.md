# Digi of Adventure on the Nexys A7 (Verilog port)

This folder is the hardware version of the Pygame game in `demo_py/` and `onlystage_3/`.
It runs on a **Digilent Nexys A7-100T** (Artix-7 XC7A100T-1CSG324C) with a VGA monitor.
The Python code is the reference ("source of truth"). Every rule, number and text was copied
from it. Where the hardware does something different, `docs/PORTING_NOTES.md` says what and why.

What is included:

| Part | Python source | Verilog |
|---|---|---|
| Opening slides, cut-scenes 1-2 and 2-3, ending (confetti, graduation) | `open.py`, `cutscene_*.py` | `rtl/flow/story.v` |
| Demo hub / stage order / hand-off (hearts, form, armor, career, card backs) | `demo_hub.py` | `rtl/flow/game_flow.v` |
| Stage 1 - Final Exam escape room (5 puzzles, notebook, help, cards) | `stage1_demo.py` | `rtl/stage1/*.v` |
| Stage 2 - Internship (part hunt, Boss, breadboard decoder, QA tests) | `stage2_demo.py` | `rtl/stage2/stage2.v` |
| Stage 3 - Graduation Run obby (3 levels, animals, reporter, skills) | `onlystage_3/*.py`, `stage3_demo.py` | `rtl/stage3/stage3.v` |
| Shared: movement/collision, 4 character forms, LFSR, cards, hearts/armor | all stages | `rtl/shared/*`, per stage |
| Video: 640x480 VGA, sprites, scaling, text | Pygame drawing | `rtl/video/*.v` |
| Buttons, switches, 7-segment, LEDs | the virtual board panel | `rtl/core/*.v`, `rtl/top/nexys_a7_top.v` |

## 1. Memory: do the pictures fit? (yes - 85.5 of 135 block RAMs)

The game has about 25 Mbit of pictures if they were stored as plain 12-bit colour. The FPGA only has
135 block RAMs (RAMB36) = 4.86 Mbit, so the pictures are **compressed** by `tools/asset_compiler.py`:

* **P4** - small pixel-art sprites (player, NPCs, animals, cards' icons): 4 bits per pixel + a 16-colour palette per picture.
  The 640-px source sprites are drawn on a 20-px grid, so storing them at 32x32 loses nothing.
* **VQ** (vector quantisation) - the big pictures (rooms, story slides, card faces, sky): every 4x4 block of pixels
  is replaced by the number of the closest block in a 512-entry "code book". 16 pixels then cost 9 bits.
* Stage 3 levels are **tile maps** (250 x 11 tile numbers per level) + 211 unique 32x32 tiles.

Result (`docs/bram_report.md` has every picture with its size and quality):

| ROM | RAMB36 |
|---|---:|
| pictures (P4 pixels, VQ indices, code books, palettes, tile maps) | 63 |
| text screen 80x60, font, UI program and strings, line buffers | 18.5 |
| Stage 2 walk mask | 4 |
| **total** | **85.5 / 135 (63 %)** |

`asset_compiler.py` stops with an error if the pictures need more than 100 RAMB36, so the design can
never silently grow past the chip. Compression factor: 12x. Trade-off: the story slides are stored at
320x180 and shown 2x, so the small Thai paragraph text inside some pictures is blurry.

## 2. Build it

You need Python 3 with Pillow (`pip install pillow`) and Vivado (2020.2 or newer; the free WebPACK edition supports
the XC7A100T). For simulation: Icarus Verilog and/or Verilator.

```bash
cd <repo>                                   # the folder that contains demo_py/, assets/, fpga/
python3 fpga/tools/asset_compiler.py .      # pictures -> fpga/mem/rom_*.mem + rtl/gen/*.vh  (takes a few minutes)
python3 fpga/tools/s2_tables.py .           # Stage 2 walk mask, spots, Boss paths, breadboard tables
python3 fpga/tools/s3_tables.py .           # Stage 3 level collision masks + animals
python3 fpga/tools/ui_compiler.py .         # all text screens -> fpga/mem/ui_prog.mem, ui_str.mem, font.mem
cd fpga
vivado -mode batch -source vivado/build.tcl          # project + synthesis + implementation + bitstream
vivado -mode batch -source vivado/program.tcl        # load the bitstream over USB
```

`vivado -mode batch -source vivado/build.tcl -tclargs create` only creates `build/vivado/digi.xpr`, which you can open
in the Vivado GUI (Run Synthesis -> Run Implementation -> Generate Bitstream -> Open Hardware Manager -> Program).
The generated files (`mem/`, `rtl/gen/`) are already in this folder, so the Python step is only needed after you change
a picture or a text.

Pins come from Digilent's official `Nexys-A7-100T-Master.xdc` (copied unchanged in `constraints/`); `tools/make_xdc.py`
only uncomments the lines for the ports the top level uses. No pin was typed by hand.

## 3. Playing on the board

| Control | Use |
|---|---|
| BTNU / BTND / BTNL / BTNR | move (Stage 3: BTNL/BTNR run, BTNU jump - press again in the air for the double jump, BTND pause) |
| BTNC tap | interact / confirm / search / pick a card (Stage 3: use the skill) |
| BTNC hold 0.8 s | back / cancel (same as Esc in Pygame) |
| CPU RESET (red) | restart from the scene chosen with SW12-SW10 |
| SW0-SW7 | Stage 1 puzzle inputs; Stage 2 SW2-SW0 = decoder test input C B A |
| SW13 | Stage 2 workshop-shirt skill |
| SW14 | notebook |
| SW15 | Stage 1 help, Stage 2 inventory |
| SW12-SW10 at reset | start scene: 0 opening, 1 Stage 1, 2 cut-scene 1-2, 3 Stage 2, 4 cut-scene 2-3, 5 Stage 3, 6 ending |
| SW9-SW8 at reset | Stage 1 checkpoint (0 start, 1 three puzzles done, 2 all puzzles, 3 at the door) |
| 7-segment | Stage 1 `H<hearts>` + puzzle code, Stage 2 `H<hearts> P<parts> <QA>` or the live decoder input/output, Stage 3 `H<hearts>StG3-<skill s>` |
| LED0-15 | hearts, armor, puzzle / skill / freeze / slow status (per stage, see the stage source headers) |
| LED16 / LED17 (RGB) | career colour / character form |

## 4. How the hardware works (short version)

Everything runs from the one 100 MHz clock. The VGA pixel rate (25 MHz) is a clock enable, so there is no clock
domain crossing.

1. **`vga_timing.v`** counts 800 x 525 pixel slots (640 x 480 visible, 60 frames per second).
2. **`line_engine.v`** draws the picture one line ahead of the monitor into a line buffer. The active stage gives it a list
   of up to 64 *objects* (picture, solid rectangle, transparent tint, Stage 3 tile map). Each object can be scaled,
   mirrored and dithered. The engine reads the compressed ROMs (P4 or VQ -> palette) and writes one pixel per clock.
3. **`ui_painter.v`** writes all text into an 80 x 60 character screen (8 x 8 font) during the blanking time. The text
   screens are small programs (generated by `tools/ui_compiler.py` from `tools/screens_*.py`); the game logic only answers
   "what is field N" and "is condition N true".
4. **Game logic** (`stage1.v`, `stage2.v`, `stage3.v`, `story.v`) runs once per frame (60 Hz) like Pygame's `update()`.
   Stage 3 runs its physics twice per frame (Pygame's 120 Hz fixed step) in Q16.16 fixed point.
5. **`game_flow.v`** switches scenes and passes the hand-off values (hearts, form, armor, shard, boost, career, card backs).

Main fixed rules copied from Python: LFSR `x^16 + x^15 + x^13 + x^4` (taps 15,14,12,3), 7 steps per frame, zero state
replaced by 0xACE1; cards = one of the 6 `itertools.permutations` picked by rejection sampling (`lfsr & 7 < 6`).

## 5. What was checked, and what was not

Be careful with the difference between **simulation**, **synthesis** and **hardware**:

| Check | Tool | Result |
|---|---|---|
| Unit tests `sim/unit/run_all.sh` | Icarus Verilog | **PASS**: LFSR = Python for 1000 steps; VGA timing 800x525 / 640x480 / sync widths; input debounce, tap, hold-back, switch edges; card deck all 6 permutations + skip; Stage 3 jump apex 2.500 tiles and double-jump apex 4.500 tiles (Pygame: 2.5 / 4.5); Stage 2 breadboard: the Pygame reference wiring shows the right character for all 6 codes, an unpowered AND chip breaks 3 of them |
| Whole-board frames `sim/verilator/` | Verilator (full top level, real ROM files, button scripts) | Rendered and inspected (`docs/screenshots/`): opening, Stage 1 card round and card face, Stage 2 Boss walk-in + intro dialogue + skill markers + walking with desk collision, Stage 3 level 1 standing, running, jumping onto a platform, falling in water and restarting |
| Lint | Verilator `--lint-only` | no errors (width warnings remain in generated tables) |
| Vivado synthesis / implementation / timing | **not run** (no Vivado in the build machine) | unknown |
| Real board | **not tested** | unknown |

So: the logic was simulated, but the design has **not** been synthesised by Vivado, timing at 100 MHz is **not**
confirmed, and it has **not** been run on a Nexys A7 yet. Things to look at first when you build it:
`report_utilization` (LUTs - the Stage 2/3 animal and wiring arrays are large) and `report_timing_summary`
(the per-object descriptor logic in the stage modules is long combinational logic; if timing fails, add a register
stage on `obj_desc` in `video_core.v`, the line engine fetches objects early enough to allow it).

## 6. Folder map

```
fpga/
  README.md                this file
  docs/bram_report.md      every ROM and picture, memory budget (generated)
  docs/PORTING_NOTES.md    differences from the Pygame game, decisions, audit of the old rtl/common/*.sv
  constraints/             Digilent master XDC (original) + the generated project XDC
  mem/                     ROM contents (.mem) read by $readmemh / $readmemb
  rtl/top, core, video     board top level, inputs, 7-segment, VGA, line engine, text painter
  rtl/shared               LFSR, card deck, sprite animation, hearts/armor, string helpers
  rtl/flow                 scene sequencer + story scenes
  rtl/stage1, stage2, stage3
  rtl/gen                  generated tables (asset ids, UI ids, Stage 2 / 3 data)
  sim/unit                 unit testbenches (Icarus): run_all.sh
  sim/verilator            whole-board simulator that writes PPM screenshots from a button script
  sim/tb_video_frame.v     video pipeline test (Icarus)
  tools/                   Python generators (assets, UI, tables, XDC)
  vivado/                  build.tcl, program.tcl
```
