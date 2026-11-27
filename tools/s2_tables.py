#!/usr/bin/env python3
"""s2_tables.py - Stage 2 (internship) data for the FPGA, taken from demo_py/stage2_demo.py.

Outputs
  fpga/mem/s2_walk.mem      walk mask of the office, 480 x 270 bits (one bit per 2x2 px of the
                            960x540 Pygame room), 1 = floor. Address = (y/2)*480 + x/2.
  fpga/rtl/gen/s2_tables.vh spots, hint notes, objects and their floor anchors (the same flood fill
                            + nearest reachable point as Game.set_anchor), the Boss walking paths
                            (find_path BFS, stored as straight segments), the breadboard: sinks,
                            sources, cursor stops, gates and the reference build (REF).
Run from the repository root:  python3 fpga/tools/s2_tables.py .
"""
import os, sys, math, types
from collections import deque
from PIL import Image, ImageDraw

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
FPGA = ROOT if os.path.isdir(os.path.join(ROOT, "rtl")) else os.path.join(ROOT, "fpga")

_STAGE2_DEMO = os.path.join(ROOT, "demo_py", "stage2_demo.py")
if not os.path.exists(_STAGE2_DEMO) and os.path.exists(os.path.join(os.path.dirname(FPGA), "demo_py", "stage2_demo.py")):
    ROOT = os.path.dirname(FPGA)
    _STAGE2_DEMO = os.path.join(ROOT, "demo_py", "stage2_demo.py")

if os.path.exists(_STAGE2_DEMO):
    def load_stage2():
        """Execute the data part of stage2_demo.py (everything before 'class Game') with a pygame stub."""
        src = open(_STAGE2_DEMO, encoding="utf-8").read()
        head = src[:src.index("class Game")]
        pg = types.ModuleType("pygame")

        class Rect:
            def __init__(self, *a):
                if len(a) == 1: a = a[0]
                self.x, self.y, self.w, self.h = a
                self.center = (self.x + self.w // 2, self.y + self.h // 2)
        pg.Rect = Rect
        pg.Surface = lambda *a, **k: None
        sys.modules["pygame"] = pg
        sys.modules.setdefault("card_assets", types.ModuleType("card_assets"))
        g = {"__name__": "stage2_data", "__file__": _STAGE2_DEMO}
        # drop the imports of modules that need a display
        lines = [l for l in head.splitlines() if not l.startswith(("import player_sprite", "from player_sprite"))]
        exec(compile("\n".join(lines), "stage2_demo.py", "exec"), g)
        return types.SimpleNamespace(**g)

    S = load_stage2()
    UW, UH = S.UW, S.UH
    _HAS_STAGE2 = True
else:
    import ui_fallback as _fb
    S = _fb.make_s2_namespace()
    _HAS_STAGE2 = False

if _HAS_STAGE2:
    # ---------------------------------------------------------------- walk mask (make_walk_mask)
    mask = Image.new("L", (UW, UH), 0)
    d = ImageDraw.Draw(mask)
    F = S.FLOOR
    d.rectangle([F.x, F.y, F.x + F.w - 1, F.y + F.h - 1], fill=255)
    for poly in S.SOLIDS:
        d.polygon(poly, fill=0, outline=0)
    M = mask.load()

    def blocked(x, y):
        x, y = int(x), int(y)
        l, r, t, b = x - S.FEET_HW, x + S.FEET_HW, y - S.FEET_H, y
        for px, py in ((l, t), (r, t), (l, b), (r, b), (x, t), (x, b), (l, (t + b) // 2), (r, (t + b) // 2)):
            if px < 0 or py < 0 or px >= UW or py >= UH or M[px, py] < 128:
                return True
        return False

    def flood(start):
        s = (int(start[0]), int(start[1]))
        seen, todo = {s}, [s]
        while todo:
            x, y = todo.pop()
            for dx, dy in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                n = (x + dx, y + dy)
                if n not in seen and not blocked(*n):
                    seen.add(n)
                    todo.append(n)
        return seen

    REACH = flood(S.SPAWN)

    def anchor(fx, fy):
        return min(REACH, key=lambda p: (p[0] - fx) ** 2 + (p[1] - fy) ** 2)

    def find_path(start, goal):
        near_cell = lambda q: min(REACH, key=lambda p: (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2)
        s, g = near_cell(start), near_cell(goal)
        prev, todo = {s: None}, deque([s])
        while todo:
            c = todo.popleft()
            if c == g: break
            for dx, dy in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                n = (c[0] + dx, c[1] + dy)
                if n in REACH and n not in prev:
                    prev[n] = c
                    todo.append(n)
        path, c = [], g
        while c is not None:
            path.append(c)
            c = prev[c]
        return path[::-1]

    def corners(path):
        """keep only the points where the direction changes (walking straight between them is identical)"""
        if len(path) <= 2: return list(path)
        out = [path[0]]
        for i in range(1, len(path) - 1):
            d0 = (path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1])
            d1 = (path[i + 1][0] - path[i][0], path[i + 1][1] - path[i][1])
            if d0 != d1: out.append(path[i])
        out.append(path[-1])
        return out

    # Boss: start_intro() walks from the door to the player (who is still at SPAWN), stops 14 steps short;
    # talk_done('intro') walks to the desk anchor, then onto the seat.
    p1 = find_path((622.0, 186.0), S.SPAWN)
    p1 = p1[:max(1, len(p1) - 14)]
    npc_a = anchor(*S.NPC_OBJ.foot)
    p2 = find_path(p1[-1], npc_a) + [(int(S.NPC_SEAT[0]), int(S.NPC_SEAT[1]))]
    PATH1, PATH2 = corners(p1), corners(p2)

# ---------------------------------------------------------------- breadboard
SINKS, SRC_LIST = S.SINKS, S.SRC_LIST
SRC_IDX = {s: i + 1 for i, s in enumerate(SRC_LIST)}          # 0 = no wire
SINK_IDX = {s: i for i, s in enumerate(SINKS)}
if _HAS_STAGE2:
    CUR = [S.SINK_POS[s] for s in SINKS] + [p for _, p in S.CUR_SRC] + [S.BTN_CLEAR.center, S.BTN_UNDO.center]
    CUR_SRC_ID = [SRC_IDX[k] for k, _ in S.CUR_SRC]
    assert len(CUR) == S.N_CUR
PART_KEYS = [k for k, _, _ in S.PARTS]


def write():
    os.makedirs(os.path.join(FPGA, "mem"), exist_ok=True)
    with open(os.path.join(FPGA, "mem", "s2_walk.mem"), "w") as f:
        for y in range(0, UH, 2):
            for x in range(0, UW, 2):
                f.write("1\n" if M[x, y] >= 128 else "0\n")
    o = []
    w = o.append
    w("// s2_tables.vh - generated by fpga/tools/s2_tables.py from demo_py/stage2_demo.py. Do not edit.")
    w("// Coordinates are Pygame room pixels (960x540 UI space).")
    w("localparam S2_NSPOTS = %d, S2_NHINTS = %d, S2_NSINKS = %d, S2_NSRC = %d, S2_NCUR = %d, S2_NREF = %d;" %
      (len(S.ITEM_SPOTS), len(S.HINT_SPOTS), len(SINKS), len(SRC_LIST), S.N_CUR, len(S.REF)))
    w("localparam S2_CUR_CLEAR = %d, S2_CUR_UNDO = %d;" % (S.CUR_CLEAR, S.CUR_UNDO))
    w("localparam [9:0] S2_SPAWN_X = %d, S2_SPAWN_Y = %d;" % S.SPAWN)
    # spots: {part4, ix10, iy10, ax10, ay10}
    w("function [43:0] s2_spot; input [4:0] i;\n  case (i)")
    for i, sp in enumerate(S.ITEM_SPOTS):
        ax, ay = anchor(*sp.foot)
        w("    5'd%d: s2_spot = {4'd%d, 10'd%d, 10'd%d, 10'd%d, 10'd%d}; // %s" %
          (i, PART_KEYS.index(sp.part), sp.ix, sp.iy, ax, ay, sp.id))
    w("    default: s2_spot = 44'd0;\n  endcase\nendfunction")
    w("function [39:0] s2_hint; input [3:0] i;\n  case (i)")
    for i, h in enumerate(S.HINT_SPOTS):
        ax, ay = anchor(*h.foot)
        w("    4'd%d: s2_hint = {10'd%d, 10'd%d, 10'd%d, 10'd%d}; // %s" % (i, h.ix, h.iy, ax, ay, h.id))
    w("    default: s2_hint = 40'd0;\n  endcase\nendfunction")
    # objects: whiteboard, door, bench, npc
    w("function [19:0] s2_obj; input [1:0] i;\n  case (i)")
    for i, ob in enumerate(S.OBJS + [S.NPC_OBJ]):
        ax, ay = anchor(*ob.foot)
        w("    2'd%d: s2_obj = {10'd%d, 10'd%d}; // %s" % (i, ax, ay, ob.id))
    w("  endcase\nendfunction")
    # parts: quantity per kind
    w("function [2:0] s2_qty; input [3:0] k;\n  case (k)")
    for i, (k, _, q) in enumerate(S.PARTS):
        w("    4'd%d: s2_qty = 3'd%d; // %s" % (i, q, k))
    w("    default: s2_qty = 3'd0;\n  endcase\nendfunction")
    # boss paths
    for name, P in (("s2_path1", PATH1), ("s2_path2", PATH2)):
        w("localparam %s_N = %d;" % (name.upper(), len(P)))
        w("function [19:0] %s; input [5:0] i;\n  case (i)" % name)
        for i, (x, y) in enumerate(P):
            w("    6'd%d: %s = {10'd%d, 10'd%d};" % (i, name, x, y))
        w("    default: %s = {10'd%d, 10'd%d};\n  endcase\nendfunction" % ((name,) + tuple(P[-1])))
    # cursor stops: {x10, y10}
    w("function [19:0] s2_cur; input [6:0] i;\n  case (i)")
    for i, (x, y) in enumerate(CUR):
        w("    7'd%d: s2_cur = {10'd%d, 10'd%d};" % (i, x, y))
    w("    default: s2_cur = 20'd0;\n  endcase\nendfunction")
    # cursor stop -> source id (for stops past the sinks)
    w("function [4:0] s2_cur_src; input [6:0] i;\n  case (i)")
    for i, s in enumerate(CUR_SRC_ID):
        w("    7'd%d: s2_cur_src = 5'd%d;" % (i + len(SINKS), s))
    w("    default: s2_cur_src = 5'd0;\n  endcase\nendfunction")
    # nodes: src id 6..27 = gates and resistors. {kind2 (0 not 1 and 2 or 3 res), unit2, in_a6, in_b6}
    w("// node(src id): kind 0 NOT, 1 AND, 2 OR, 3 220-ohm resistor; unit U1..U4; input sinks (63 = none)")
    w("function [15:0] s2_node; input [4:0] s;\n  case (s)")
    for sname in SRC_LIST:
        sid = SRC_IDX[sname]
        if sname in S.GATES:
            kind, unit, _, _ = S.GATES[sname]
            ins = [SINK_IDX[x] for x in S.GATE_IN[sname]] + [63]
            w("    5'd%d: s2_node = {2'd%d, 2'd%d, 6'd%d, 6'd%d}; // %s" %
              (sid, {"not": 0, "and": 1, "or": 2}[kind], S.UNITS.index(unit), ins[0], ins[1], sname))
        elif sname[0] == "R" and len(sname) == 2:
            w("    5'd%d: s2_node = {2'd3, 2'd0, 6'd%d, 6'd63}; // %s" % (sid, SINK_IDX["s" + sname[1]], sname))
    w("    default: s2_node = 16'hFFFF;\n  endcase\nendfunction")
    w("// sinks of the chip supply pins, DIP, pull-downs, display")
    for u in S.UNITS:
        w("localparam S2_%s_VCC = %d, S2_%s_GND = %d;" % (u, SINK_IDX[u + ".vcc"], u, SINK_IDX[u + ".gnd"]))
    w("localparam S2_DIPVCC = %d, S2_PDC = %d, S2_PDB = %d, S2_PDA = %d, S2_SEGCOM = %d, S2_SEG_S0 = %d, S2_SEG_D0 = %d;" %
      (SINK_IDX["dip.vcc"], SINK_IDX["pd.C"], SINK_IDX["pd.B"], SINK_IDX["pd.A"], SINK_IDX["seg.com"],
       SINK_IDX["sa"], SINK_IDX["da"]))
    w("localparam S2_SRC_1 = %d, S2_SRC_0 = %d, S2_SRC_C = %d, S2_SRC_B = %d, S2_SRC_A = %d, S2_SRC_N1 = %d, S2_SRC_RA = %d;" %
      (SRC_IDX["1"], SRC_IDX["0"], SRC_IDX["C"], SRC_IDX["B"], SRC_IDX["A"], SRC_IDX["N1"], SRC_IDX["Ra"]))
    # reference build: {sink6, src5}
    w("function [10:0] s2_ref; input [5:0] i;\n  case (i)")
    for i, (sk, sr) in enumerate(S.REF):
        w("    6'd%d: s2_ref = {6'd%d, 5'd%d}; // %s <- %s" % (i, SINK_IDX[sk], SRC_IDX[sr], sk, sr))
    w("    default: s2_ref = 11'd0;\n  endcase\nendfunction")
    # GOLD: segments a..g (bit 6 = a) of the character for code k
    w("function [6:0] s2_gold; input [2:0] k;\n  case (k)")
    for k, segs in S.GOLD.items():
        w("    3'd%d: s2_gold = 7'b%s; // %s" % (k, "".join("1" if s in segs else "0" for s in "abcdefg"), S.CHAR_NAME[k]))
    w("    default: s2_gold = 7'd0;\n  endcase\nendfunction")
    open(os.path.join(FPGA, "rtl", "gen", "s2_tables.vh"), "w").write("\n".join(o) + "\n")
    print("s2_tables: reach %d cells, path1 %d corners, path2 %d corners, %d sinks, %d cursor stops" %
          (len(REACH), len(PATH1), len(PATH2), len(SINKS), S.N_CUR))


# names used by screens_s2.py (strings for the hints / status line)
def sink_names():
    if not _HAS_STAGE2:
        return [("K%d" % i, n) for i, n in enumerate(_fb.S2_SINK_NAMES)]
    return [(("K%d" % i), S.sink_name(s)) for i, s in enumerate(SINKS)]


def src_names():
    if not _HAS_STAGE2:
        return [("NONE", _fb.S2_SRC_NAMES[0])] + [("S%d" % (i + 1), n) for i, n in enumerate(_fb.S2_SRC_NAMES[1:])]
    return [("NONE", "(no wire)")] + [("S%d" % (i + 1), S.src_name(s)) for i, s in enumerate(SRC_LIST)]


if __name__ == "__main__":
    write()
