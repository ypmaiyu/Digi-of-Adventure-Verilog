# Porting notes: Pygame -> Verilog

The Pygame files are the reference. This page lists every place where the FPGA version is
different, and why. "Faithful" means the hardware copies a Python behaviour that may look odd.

## Things where the task description and the Python code disagree (Python was followed)

| Topic | Task description | Python code (used) |
|---|---|---|
| Stage 1 card round 1, yellow card | Speed Boost | a hint card (`CARD_ITEMS[1]`) |
| Freeze item | slows enemies | the *player* cannot move for 10 s (`speed()` returns 0) |
| Stage 3 | uses boost / freeze | `onlystage_3` never reads them; only the Cloak / Phase skills exist |
| Character form in Stage 3 | form 3 | Stage 3 shows the gown (form 2); gold / Phase looks come from the milk tea and the skill |
| Stage 1 map timers | - | slow / freeze count down twice per frame in map mode (`update()` and `map_update()` both subtract `dt`) - faithful |
| Stage 2 skill | usable after 2 minutes | `try_skill()` does not check the 2-minute wait (only the button text does) - faithful |
| Stage 2 inventory "Undo" / "Freeze" | usable items | `use_item()` has no branch for Undo and the Freeze counter is never filled - faithful (nothing happens / "You do not have this item") |

## General

* **Fonts**: one 8x8 pixel font (`tools/font8x8.py`, uppercase/digits from `onlystage_3/pixel_type.py`) replaces the
  TrueType fonts. Big titles use the same font at 2x. Only ASCII is available.
* **Screen**: Pygame's 960x540 UI becomes a 640x360 picture area between a title bar (top) and a control-help bar
  (bottom) on the 640x480 VGA screen. All coordinates are scaled by 2/3.
* **Rounded rectangles, circles, anti-aliasing, alpha blending**: rectangles are square; transparency is a 16-level tint
  (`K_BLEND`) or a 50 % checkerboard dither.
* **Random numbers**: the same LFSR and the same rejection sampling as Python, but the seed is fixed at reset
  (Python seeds from the clock) and the LFSR also runs while you wait, so results still depend on human timing.

## Story scenes

* Slides are stored at 320x180 (VQ) and shown 2x. Paragraph text that is part of the picture is soft.
* Cross-fades use a dither pattern instead of real alpha.

## Stage 1

* Complete port (puzzles, K-map, locks, notebook, help, intro with the TA, cards, hearts/armor, lights, projector).
* Collision uses the same rectangles as the Python code (`s1_collision.v`).

## Stage 2

* **Wires** are not drawn as curves. Each white pin shows the name of the source it is wired to
  (`+5`, `GN`, `C`, `B`, `A`, `N1`..`N3`, `A1`..`A4`, `O1`..`O8`, `Ra`..`Rg`). The cursor, selected source,
  segment outputs and power lamps work like the Python board.
* **Logic simulation**: Python evaluates the circuit recursively and reads 0 when it meets a loop. The hardware
  evaluates all gates 24 times (enough for the deepest real circuit). Without loops the result is identical (tested
  with the Python reference wiring); a wiring loop may give a different, oscillating value.
* **Undo** keeps the last 64 changes (Python: 200). Clear-all keeps the last 2 snapshots.
* **Mouse** clicks do not exist; the keyboard / button path (`cursor_step`, pick source, wire pin) is used.
* **Close-up pictures** (`closeup_*.png`) are not in the repository, so close-ups are drawn as plain panels like Python
  does when the file is missing.
* **Found-part zoom**: the room picture zooms to 2.6x around the spot (0.5 s), the "found" card is shown as the toast
  text "Found: <part> (n/q)".
* **Walk mask** is stored on a 2 px grid (Python: 1 px). The 8 foot test points and the 4-20 px "glide" are the same.
* **Boss path**: the breadth-first path is precomputed by `tools/s2_tables.py` from the same mask, start and goal; the
  Boss walks it at 150 px/s. The last step onto the chair (not on the grid) is done x first, then y.
* **Notebook** shows the last 8 logged actions; the "hints used" list is not shown.
* **Game over** restarts the stage with the Stage-1 card backs kept (Python draws new random backs).
* The help page is not shown at stage start (Python `start()` hides it as well).

## Stage 3

* Physics, timers, double jump (square root and division), coyote time, jump buffer, water / falling, the ? block,
  milk tea, lifts, door and stage clear follow `game.py`. Checked in `sim/unit/tb_stage3_jump.v`.
* The reporter follows 0.28 s behind on the recorded route but does not search for a free standing spot when that
  point is blocked; its retreat walks straight away instead of replaying the trail.
* Animal followers start following after 0.5 s of leader history.
* Snowfall, footprints, wind lines and sparkles are not drawn.

## Audit of the original `rtl/common/*.sv` and `tb/*.sv`

The repository already had SystemVerilog sketches. They were read and replaced (the task asks for Verilog `.v`):

| Old file | Status | Replacement |
|---|---|---|
| `lfsr16.sv` | same taps and zero guard as Python - correct | `rtl/shared/lfsr.vh` (+ 7-step function) |
| `card_deck.sv` | correct idea (rejection sampling, cursor), one-hot face, no round-3 skip | `rtl/shared/card_deck.v` |
| `button_unit.sv`, `input_hub.sv` | debounce, one-shot and long-press detection - reworked with the Pygame 0.8 s hold rule and frame-aligned events | `rtl/core/input_ctrl.v` |
| `heart_system.sv`, `item_effect.sv`, `inventory.sv`, `hint_selector.sv`, `card_trigger.sv`, `door_lock.sv` | partial Stage 1 rules | inside `rtl/stage1/stage1.v`, `rtl/shared/heart_armor.v` |
| `reset_sync.sv`, `tick_gen.sv`, `game_pkg.sv` | helpers / package (SystemVerilog only) | `rtl/top/nexys_a7_top.v`, local parameters |
| `rtl/stage1/stage1_controller.v`, `vga_renderer.v` | empty files | `rtl/stage1/*.v`, `rtl/video/*.v` |
| `tb/tb_*.sv` | SystemVerilog testbenches for the old modules | `fpga/sim/unit/*.v` |

The old files were left untouched so nothing of the team's work is lost.
