"""Stage 2 (internship) text screens - port of the drawing code of demo_py/stage2_demo.py.

Coordinates are the 960x540 Pygame UI space (close-ups use the 640-wide surface placed at x=160).
Pictures, rails, chips, resistors, 7-segment displays and the cursor are line-engine objects in
rtl/stage2/stage2.v; this file only places text."""
import screens_common
import s2_tables as T

S = T.S
WHITE, GOLD, LBLUE, MUTED, GREEN, RED = (255, 255, 255), (255, 230, 120), (170, 200, 255), (143, 161, 184), (150, 255, 170), (255, 120, 120)
INK = (30, 40, 130)

# "Found: <part>" toasts (count shown by the S2_TOAST program)
for _k, _n, _q in S.PARTS:
    screens_common.TOASTS.append(("FOUND_" + _k.upper(), "Found: " + _n))
screens_common.TOASTS.append(("ARMOR_PROT2", "ARMOR PROTECTED!"))

SRC_SHORT = {"1": "+5", "0": "GN", "C": "C", "B": "B", "A": "A"}


def src_short(s):
    return SRC_SHORT.get(s, s)


def card_descs_s2():
    return [("S2_HINT", "Use it from the inventory (SW15)."),
            ("S2_SHARD", "Collect 2 shards to forge 1 Armor."),
            ("S2_FREEZE", "You are frozen in place for 10 seconds."),
            ("S2_HEART_LOSS", "Oops! You lost 1 heart immediately!"),
            ("S2_HEART_ARMOR", "Oops! ... but your Armor protected you.")]


def talk_lines():
    L = [("I%d" % i, t) for i, t in enumerate(S.INTRO_LINES)]
    L[2] = ("I2", S.INTRO_LINES[2].replace("press Space", "press BTNC"))
    L[4] = ("I4", S.INTRO_LINES[4].replace("(key E, or flip SW13)", "(flip SW13)"))
    L += [("INFO0", "Come back when the decoder is built."),
          ("INFO1", "Find all 18 parts, install them on the decoder bench, then wire the breadboard."),
          ("DONE", "Everything is verified. Leave through the exit door!"),
          ("ASK0", "Is your circuit finished?")]
    for r in range(S.ROUNDS):
        L.append(("ASK1_%d" % r, "QA test %d of %d: I will check the two inputs of the work order.   "
                                 "BTNC = test it     hold BTNC = not yet" % (r + 1, S.ROUNDS)))
    L.append(("TEST", "Let me test your circuit..."))
    for k in range(1, 7):
        for ok in (0, 1):
            L.append(("IN%d_%d" % (k, ok), "Input %d%d%d (must show %s): %s" %
                      (S.bits(k) + (S.CHAR_NAME[k], "correct!" if ok else "WRONG."))))
    L.append(("ALLPASS", "All %d tests passed! The decoder is verified. You may leave through the exit door." % S.ROUNDS))
    for r in range(S.ROUNDS - 1):
        L.append(("PASS%d" % r, "Test %d of %d passed!" % (r + 1, S.ROUNDS)))
    L.append(("FAIL", "Not right. Go back to the bench and fix it."))
    return L


def notes():
    N = [("NONE", "")]
    for sp in S.ITEM_SPOTS:
        N.append(("F_" + sp.id.upper(), "Found %s (%s)" % (S.PART_SHORT[sp.part], sp.name)))
    for h in S.HINT_SPOTS:
        N.append(("H_" + h.id.upper(), "Hint: " + h.title))
    N += [("BOSS", "Boss: bring the finished circuit to me (desk on the right)."),
          ("BENCH", "All parts installed. Bench powered on.")]
    for r in range(S.ROUNDS):
        for g in range(3):
            N.append(("QA%d_%d" % (r, g), "QA test %d: Boss says %d/2 correct" % (r + 1, g)))
    return N


def build_s2(ui):
    ui.table("T_S2_TALK", talk_lines(), wrap_chars=68)
    hints = [("H%d" % i, h.text.replace("press Space", "press BTNC").replace("notebook (N)", "notebook (SW14)"))
             for i, h in enumerate(S.HINT_SPOTS)]
    hints += [("C%d" % i, "Clue: " + sp.clue) for i, sp in enumerate(S.ITEM_SPOTS)]
    hints += [("BENCH", "All parts found. Go to the decoder bench and power it on."),
              ("MATCH", "Every segment already matches. Show it to the Boss."),
              ("TRY", "Try this next: wire the")]
    ui.table("T_S2_HINT", hints, wrap_chars=50)
    ui.table("T_S2_HTITLE", [("H%d" % i, h.title) for i, h in enumerate(S.HINT_SPOTS)] + [("HINT", "HINT")])
    ui.table("T_S2_NOTE", notes(), wrap_chars=44)
    ui.table("T_S2_SINK", T.sink_names())
    ui.table("T_S2_SRC", T.src_names())
    ui.table("T_S2_CMSG", [("NONE", ""), ("UNDO0", "Nothing to undo."),
                           ("LOCKED", "Locked. It opens when the decoder passes QA."),
                           ("MISSING", "Cannot power on. Missing parts: see the tray list above."),
                           ("AUTOWIRE", "Auto-wired reference decoder via SW8.")])
    ui.table("T_S2_SKILL", [("WAIT", "SKILL"), ("READY", "SKILL [SW13] READY"), ("ON", "SKILL ON"), ("USED", "SKILL USED")])
    ui.table("T_S2_CAREER", [("AIR", "Career card: AIR"), ("EARTH", "Career card: EARTH"), ("WATER", "Career card: WATER")])
    ui.table("T_S2_CHAR", [("K%d" % k, S.CHAR_NAME.get(k, " ")) for k in range(8)])

    # ---------------- map HUD extras: parts / QA counters, skill button ----------------
    p = ui.program("S2_HUD")
    at = p.if_("C_S2_COUNTERS")
    p.txt("Parts", 820, 36, "s", GREEN)
    p.fld("F_S2_PARTS", 820 + 6 * 12, 36, "s", GREEN, 5)
    p.txt("QA", 868, 48, "s", GOLD)
    p.fld("F_S2_QA", 868 + 3 * 12, 48, "s", GOLD, 3)
    p.end(at)
    at = p.if_("C_S2_SKILLBTN")
    p.rect(696, 64, 252, 28, (50, 50, 56), border=WHITE)
    p.sel("T_S2_SKILL", "F_S2_SKILL", 714, 69, "s", WHITE)
    p.fld("F_S2_SKILL_T", 870, 69, "s", WHITE, 5)
    p.end(at)
    at = p.if_("C_S2_FREEZE_ON")
    p.txt("FREEZE", 290, 36, "m", (140, 220, 255))
    p.fld("F_FREEZE_S", 290 + 7 * 12, 36, "m", (140, 220, 255), 4)
    p.end(at)

    # ---------------- toast (draw_toast) + count ----------------
    p = ui.program("S2_TOAST")
    p.strsel_c(40, 3, "T_TOAST", "F_TOAST", WHITE, center=True, bg=(0, 0, 0))
    at = p.if_("C_S2_TOAST_CNT")
    p.field_c(37, 4, "F_S2_TOAST_N", WHITE, 7, bg=(0, 0, 0))
    p.end(at)

    # ---------------- Boss dialogue (draw_talk) ----------------
    p = ui.program("S2_TALK")
    p.rect(40, 372, 880, 144, (14, 18, 28), border=(255, 230, 120))
    p.txt("Boss", 62, 382, "m", (255, 230, 120))
    p.sel("T_S2_TALK", "F_S2_TALK", 62, 406, "m", WHITE, lh=14)
    at = p.if_("C_S2_ASKLAST")
    p.txt("BTNC: yes     hold BTNC: not yet", 904 - 33 * 12, 476, "s", LBLUE)
    p.end(at)
    at = p.if_("C_S2_ASKLAST", neg=True)
    p.txt("BTNC: next", 904 - 10 * 12, 476, "s", LBLUE)
    p.end(at)

    # ---------------- hint popup ----------------
    p = ui.program("S2_HINTBOX")
    p.rect(150, 120, 660, 260, (18, 24, 40), border=GOLD)
    p.sel("T_S2_HTITLE", "F_S2_HTITLE", 480, 132, "m", GOLD, center=True)
    p.sel("T_S2_HINT", "F_S2_HINT", 180, 170, "m", WHITE, lh=24)
    at = p.if_("C_S2_HINT_WIRE")
    p.sel("T_S2_SINK", "F_S2_HSINK", 180, 200, "m", (255, 225, 120))
    p.txt("to the", 180, 230, "m", WHITE)
    p.sel("T_S2_SRC", "F_S2_HSRC", 180 + 7 * 12, 230, "m", (255, 225, 120))
    p.end(at)
    p.ctxt("BTNC: close", 480, 350, "s", LBLUE)

    # ---------------- close-up frame (draw_closeup), surface at x=160 ----------------
    p = ui.program("S2_CU_FRAME")
    p.ox = 160
    p.rect(0, 0, 640, 44, (70, 74, 90))
    p.rect(0, 480, 640, 44, (40, 44, 60))
    p.txt("Back: hold BTNC", 16, 504, "s", (140, 150, 180))
    at = p.if_("C_S2_CMSG")
    p.sel("T_S2_CMSG", "F_S2_CMSG", 16, 434, "m", (255, 225, 120))
    p.end(at)

    p = ui.program("S2_CU_WB")
    p.ox = 160
    p.txt("WORK-ORDER BOARD", 16, 10, "l")
    p.rect(40, 56, 560, 376, (240, 240, 235))
    at = p.if_("C_S2_PAGE0")
    lines = ["WORK ORDER #402", "Build the 7-segment decoder.",
             "1. Hunt for all 18 lab parts in the office.", "   (notes and screens hold hints)",
             "2. Bring them to the decoder bench", "   to the middle right.", "3. Wire it, then show it to the Boss.", "",
             "input CBA -> character", "001 = C   010 = P   011 = E", "100 = -   101 = 3   110 = 9",
             "(000 and 111 never occur)"]
    for i, l in enumerate(lines):
        p.txt(l, 62, 66 + i * 30, "m", INK)
    p.txt("BTNC: next page", 16, 484, "s", LBLUE)
    p.end(at)
    at = p.if_("C_S2_PAGE1")
    p.txt("EQUIPMENT LIST", 62, 68, "l", INK)
    for i, (k, name, q) in enumerate(S.PARTS):
        y = 110 + i * 30
        p.fld("F_S2_CHK%d" % i, 62, y, "m", INK, 3)
        p.txt("%-26s x%d" % (name, q), 62 + 4 * 12, y, "m", INK)
        p.fld("F_S2_FOUND%d" % i, 62 + 34 * 12, y, "m", INK, 10)
    p.txt("Total:", 62, 396, "m", INK)
    p.fld("F_S2_PARTS", 62 + 7 * 12, 396, "m", INK, 5)
    p.txt("BTNC: next page", 16, 484, "s", LBLUE)
    p.end(at)
    at = p.if_("C_S2_PAGE2")
    p.txt("QA TEST", 70, 76, "l", INK)
    p.fld("F_S2_QA_OF", 70 + 9 * 16, 76, "l", INK, 6)
    at2 = p.if_("C_S2_QA_DONE")
    p.txt("All QA tests passed. Go to the exit door.", 70, 140, "m", (20, 120, 40))
    p.end(at2)
    at2 = p.if_("C_S2_NOCODES")
    p.wraptxt("The QA inputs appear here once the decoder bench is powered on.", 70, 140, 500, "m", INK)
    p.end(at2)
    at2 = p.if_("C_S2_SHOWCODES")
    for i in range(2):
        p.txt("input CBA =", 70, 140 + i * 130, "m", INK)
        p.fld("F_S2_CODE%d" % i, 70 + 12 * 12, 140 + i * 130, "m", INK, 3)
        p.txt("->  show", 70 + 16 * 12, 140 + i * 130, "m", INK)
        p.fld("F_S2_CHAR%d" % i, 70 + 25 * 12, 140 + i * 130, "l", INK, 1)
    p.end(at2)
    for i in range(S.ROUNDS):
        p.fld("F_S2_TEST%d" % i, 70, 366 + i * 20, "s", INK, 36)
    p.txt("BTNC: first page", 16, 484, "s", LBLUE)
    p.end(at)

    p = ui.program("S2_CU_DOOR")
    p.ox = 160
    p.txt("EXIT DOOR", 16, 10, "l")
    at = p.if_("C_S2_QA_DONE")
    p.ctxt("UNLOCKED", 320, 320, "l", (34, 197, 94))
    p.txt("BTNC: leave the lab", 16, 484, "s", LBLUE)
    p.end(at)
    at = p.if_("C_S2_QA_DONE", neg=True)
    p.ctxt("LOCKED", 320, 320, "l", RED)
    p.ctxt("The lock is wired to the decoder bench.", 320, 394, "s", (200, 200, 210))
    p.txt("BTNC: try the handle", 16, 484, "s", LBLUE)
    p.end(at)
    p.txt("Decoder QA:", 320 - 8 * 12, 362, "m")
    p.fld("F_S2_QA", 320 + 4 * 12, 362, "m", WHITE, 3)

    p = ui.program("S2_CU_BENCH")
    p.ox = 160
    p.txt("DECODER BENCH", 16, 10, "l")
    p.rect(40, 56, 560, 366, (10, 20, 10))
    p.txt("DECODER BENCH - PARTS TRAY", 56, 64, "m", (110, 255, 130))
    for i, (k, name, q) in enumerate(S.PARTS):
        y = 92 + i * 32
        p.fld("F_S2_OK%d" % i, 64, y + 5, "m", (110, 255, 130), 4)
        p.txt("%-27s" % name, 120, y + 5, "m", (210, 230, 210))
        p.fld("F_S2_HAVE%d" % i, 120 + 28 * 12, y + 5, "m", (110, 255, 130), 6)
    at = p.if_("C_S2_QA_DONE")
    p.txt("DECODER VERIFIED.", 56, 392, "m", (255, 255, 120))
    p.end(at)
    at = p.if_("C_S2_BENCH_READY")
    p.txt("All parts on the bench. Ready to power on.", 56, 392, "m", (255, 255, 120))
    p.end(at)
    at = p.if_("C_S2_BENCH_MISSING")
    p.txt("Parts", 56, 392, "m", (110, 255, 130))
    p.fld("F_S2_PARTS", 56 + 6 * 12, 392, "m", (110, 255, 130), 5)
    p.txt(". Search the office for hints.", 56 + 11 * 12, 392, "m", (110, 255, 130))
    p.end(at)
    p.txt("BTNC: power on / open the breadboard", 16, 484, "s", LBLUE)

    # ---------------- the breadboard (draw_board) ----------------
    p = ui.program("S2_BOARD")
    p.rect(0, 0, 960, 44, (34, 40, 54))
    p.txt("DECODER BENCH", 36, 8, "l")
    p.fld("F_S2_WIRES", 520, 14, "s", MUTED, 14)
    p.txt("SW8: AUTO-WIRE", 760, 14, "s", GOLD)
    for i in range(2):
        x = 24 + i * 254
        p.txt("CBA=", x + 10, 52, "s", MUTED)
        p.fld("F_S2_CODE%d" % i, x + 58, 52, "s", WHITE, 3)
        p.txt("YOUR:", x + 132, 52, "s", MUTED)
        p.txt("WANT:", x + 10, 80, "s", GOLD)
        p.fld("F_S2_CHAR%d" % i, x + 70, 76, "l", GOLD, 1)
    p.ctxt("QA TEST", 590, 54, "s", MUTED)
    p.fld("F_S2_QA_OF", 590 - 24, 74, "m", WHITE, 6)
    for cond, btn_lbl, cx in (("C_S2_HOT_UNDO", "UNDO", 709), ("C_S2_HOT_CLEAR", "CLEAR ALL", 867)):
        at = p.if_(cond)
        p.ctxt(btn_lbl, cx, 64, "s", (20, 20, 20))
        p.end(at)
        at = p.if_(cond, neg=True)
        p.ctxt(btn_lbl, cx, 64, "s", WHITE)
        p.end(at)
    for idx_r, (kind, y) in enumerate(S.RAIL_LINES):
        red = kind == "1"
        p.txt("+5V" if red else "GND", 564, y + (10 if idx_r in (0, 2) else -10), "s",
              (220, 70, 70) if red else (80, 110, 230))
    # IC labels, pin functions (+/G/A/B/Y) and gate names inside each IC body
    for u in S.IC_X:
        ix, iy = S.IC_X[u], S.IC_Y[u]
        p.txt("%s %s" % (u, S.IC_TYPE[u]), ix + 48, iy + 24, "s", (230, 230, 230))
        top_lbl = "+ B A Y B A Y" if u != "U1" else "+            "
        bot_lbl = "A Y A Y A Y G" if u == "U1" else "A B Y A B Y G"
        p.text_c(p.col(ix + 12), p.rowr(iy + 2), top_lbl, (175, 195, 225))
        p.text_c(p.col(ix + 12), p.rowr(iy + 50), bot_lbl, (175, 195, 225))
    p.text_c(p.col(190 + 12) + 1, p.rowr(150 + 36), "N1  N2  N3", GOLD)
    p.text_c(p.col(400 + 12) + 2, p.rowr(150 + 14), "A4    A3", GOLD)
    p.text_c(p.col(400 + 12) + 1, p.rowr(150 + 36), "A1    A2", GOLD)
    p.text_c(p.col(190 + 12) + 2, p.rowr(330 + 14), "O4    O3", GOLD)
    p.text_c(p.col(190 + 12) + 1, p.rowr(330 + 36), "O1    O2", GOLD)
    p.text_c(p.col(400 + 12) + 2, p.rowr(330 + 14), "O8    O7", GOLD)
    p.text_c(p.col(400 + 12) + 1, p.rowr(330 + 36), "O5    O6", GOLD)
    p.txt("DC SUPPLY", 32, 128, "s", (225, 228, 235))
    p.txt("5.00 V", 44, 148, "m", (90, 255, 110))
    p.txt("+5", 122, 174, "s", (255, 120, 120))
    p.txt("GN", 148, 174, "s", (140, 170, 255))
    p.txt("DIP SW", 32, 214, "s", (225, 235, 255))
    p.txt("+5", 108, 214, "s", (255, 130, 130))
    for i, (n, swi) in enumerate((("C", 2), ("B", 1), ("A", 0))):
        y = 238 + i * 32
        p.txt(n, 30, y - 6, "s")
        p.txt("SW%d" % swi, 108, y - 6, "s", (200, 215, 255))
        p.txt(n, 172, y - 6, "s", (30, 40, 60))
    for i, n in enumerate("CBA"):
        p.txt(n, 46 + i * 36 - 3, 400, "s", (60, 60, 55))
    p.txt("10k to GND", 30, 424, "s", (95, 95, 85))
    for i, s in enumerate(S.SEGS):
        p.txt("220 R" + s, 634, 150 + i * 48 - 22, "s", (70, 70, 85))
        p.txt(s, 774, 136 + i * 32, "s", (200, 200, 210))
    for ch, lx, ly in (("A", 848, 132), ("B", 904, 192), ("C", 904, 266), ("D", 848, 326),
                       ("E", 802, 266), ("F", 802, 192), ("G", 848, 224)):
        p.txt(ch, lx, ly, "s", GOLD)
    p.txt("COM", 902, 306, "s", (60, 60, 55))
    p.ctxt("7-SEGMENT", 850, 346, "s", (180, 180, 195))
    p.rect(756, 366, 184, 56, (17, 26, 43))
    p.ctxt("INPUT CBA=", 828, 374, "s")
    p.fld("F_S2_LIVE", 900, 374, "s", WHITE, 3)
    p.fld("F_S2_SHOULD", 768, 396, "s", MUTED, 14)
    p.rect(756, 430, 184, 62, None, border=(40, 60, 95))
    p.txt("POWER", 768, 434, "s", MUTED)
    for i, u in enumerate(S.UNITS):
        p.txt(u, 780 + i * 36, 464, "s", MUTED)
    p.fld("F_S2_PWRTXT", 768, 478, "s", MUTED, 15)
    # pins: sources (coloured dots) and sinks (white rings) + high-contrast label of each wire
    for src, pts in S.SRC_POS.items():
        col = S.src_color(src)
        for (x, y) in pts:
            p.char_c(p.col(x - 6), p.rowr(y - 6), 0x01, col)
    for i, sink in enumerate(S.SINKS):
        x, y = S.SINK_POS[sink]
        p.char_c(p.col(x - 6), p.rowr(y - 6), 0x02, WHITE)
        if y in (S.IC_Y["U1"] - 14, S.IC_Y["U3"] - 14):
            lx, ly = x - 12, y - 22                      # top row of a chip: label above
        elif y in (S.IC_Y["U1"] + S.BODY_H + 14, S.IC_Y["U3"] + S.BODY_H + 14) or sink.startswith("pd"):
            lx, ly = x - 12, y + 10                      # bottom row / pull-downs: label below
        elif sink == "dip.vcc":
            lx, ly = x + 10, y - 6
        else:
            lx, ly = x - 34, y - 6                       # resistor inputs, display pins, COM: label left
        tag_fg = (15, 35, 130) if (i % 2 == 0) else (150, 25, 30)
        p.field_c(p.col(lx), p.rowr(ly), "F_S2_P%02d" % i, tag_fg, 2)
    # status line (bottom bar)
    p.rect(0, 502, 960, 38, (34, 40, 54))
    bx = 36
    at = p.if_("C_S2_ST_CMSG")
    p.sel("T_S2_CMSG", "F_S2_CMSG", bx, 505, "s", (255, 225, 120))
    p.end(at)
    at = p.if_("C_S2_ST_DONE")
    p.txt("Decoder verified. Leave through the exit door.", bx, 505, "s", GREEN)
    p.end(at)
    at = p.if_("C_S2_ST_EDIT")
    p.sel("T_S2_SINK", "F_S2_ST_SINK", bx, 505, "s", GOLD)
    p.txt("<-", bx + 38 * 12, 505, "s", GOLD)
    p.sel("T_S2_SRC", "F_S2_ST_SRC", bx + 41 * 12, 505, "s", GOLD)
    p.end(at)
    at = p.if_("C_S2_ST_MSEL")
    p.txt("Selected:", bx, 505, "s", (130, 215, 255))
    p.sel("T_S2_SRC", "F_S2_MSEL", bx + 10 * 12, 505, "s", (130, 215, 255))
    p.txt("-> now move to a white pin", bx + 44 * 12, 505, "s", (130, 215, 255))
    p.end(at)
    at = p.if_("C_S2_ST_UNDO")
    p.txt("Press BTNC to undo the last wire change", bx, 505, "s", MUTED)
    p.end(at)
    at = p.if_("C_S2_ST_SRC")
    p.sel("T_S2_SRC", "F_S2_ST_SRC", bx, 505, "s", MUTED)
    p.txt("-> BTNC to pick, then move to white pin", bx + 34 * 12, 505, "s", MUTED)
    p.end(at)
    at = p.if_("C_S2_ST_SINK")
    p.sel("T_S2_SINK", "F_S2_ST_SINK", bx, 505, "s", MUTED)
    p.txt("=", bx + 38 * 12, 505, "s", MUTED)
    p.sel("T_S2_SRC", "F_S2_ST_SRC", bx + 41 * 12, 505, "s", MUTED)
    p.end(at)
    at = p.if_("C_S2_ST_CLEAR")
    p.txt("Press BTNC to remove every wire", bx, 505, "s", MUTED)
    p.end(at)
    p.txt("Arrows:move | BTNC:pick/wire | hold:back | SW2-0:test | SW8:auto-wire", bx, 524, "s", (140, 150, 180))

    # ---------------- inventory (SW15) ----------------
    p = ui.program("S2_INV")
    p.ox = 160
    p.rect(40, 80, 560, 340, (30, 35, 45), border=WHITE)
    p.ctxt("INVENTORY  (SW15 to close)", 320, 94, "m")
    names = ["Wire Hint", "Area Hint", "Undo", "Freeze"]
    for i in range(4):
        x = 48 + i * 136
        at = p.if_("C_S2_INV%d" % i)
        p.rect(x, 130, 132, 90, (255, 230, 120))
        p.end(at)
        p.ctxt(names[i], x + 66, 144, "s")
        p.fld("F_S2_INVN%d" % i, x + 66 - 12, 176, "l", WHITE, 2)
    p.txt("Parts", 64, 240, "s", GREEN)
    p.fld("F_S2_PARTS", 64 + 6 * 12, 240, "s", GREEN, 5)
    p.txt("Armor x", 64, 268, "s")
    p.fld("F_ARMOR_N", 64 + 7 * 12, 268, "s", WHITE, 1)
    p.txt("(shields failed QA penalty)", 64 + 10 * 12, 268, "s")
    p.txt("Armor shards:   / 2  (2 = 1 armor)", 64, 294, "s")
    p.fld("F_S2_SHARD", 64 + 14 * 12, 294, "s", WHITE, 1)
    p.txt("Speed Boost:      (for Stage 3)", 64, 320, "s")
    p.fld("F_S2_BOOST", 64 + 13 * 12, 320, "s", WHITE, 3)
    p.txt("Slow:", 64, 346, "s")
    p.fld("F_S2_SLOW", 64 + 6 * 12, 346, "s", WHITE, 10)
    p.ctxt("L/R select   BTNC use", 320, 386, "s", LBLUE)

    # ---------------- notebook (SW14) ----------------
    p = ui.program("S2_NOTEBOOK")
    p.ox = 160
    p.rect(24, 50, 592, 420, (30, 35, 45), border=WHITE)
    p.ctxt("NOTEBOOK  (SW14 to close)", 320, 62, "m")
    p.txt("Parts", 48, 92, "s", GOLD)
    p.fld("F_S2_PARTS", 48 + 6 * 12, 92, "s", GOLD, 5)
    p.txt("QA tests passed:", 48 + 14 * 12, 92, "s", GOLD)
    p.fld("F_S2_QA", 48 + 31 * 12, 92, "s", GOLD, 3)
    for i, (k, _, q) in enumerate(S.PARTS):
        cx = 48 + (i % 3) * 184
        p.txt(S.PART_SHORT[k], cx, 116 + (i // 3) * 18, "s", (230, 230, 230))
        p.fld("F_S2_FOUND%d" % i, cx + 11 * 12, 116 + (i // 3) * 18, "s", (150, 255, 170), 3)
    p.sel("T_S2_CAREER", "F_S2_CAREER", 48, 176, "s", GOLD)
    p.txt("Logged Actions & Clues:", 48, 198, "s", LBLUE)
    for i in range(8):
        p.sel("T_S2_NOTE", "F_S2_NOTE%d" % i, 48, 228 + i * 24, "s", (230, 230, 230), lh=13)

    # ---------------- game over / clear ----------------
    p = ui.program("S2_OVER")
    p.ctxt("OUT OF HEARTS", 480, 220, "l", (255, 90, 90))
    p.ctxt("Restarting Stage 2...", 480, 270, "m")
    p = ui.program("S2_CLEAR")
    p.ctxt("STAGE 2 CLEAR - INTERNSHIP COMPLETE!", 480, 160, "l", GREEN)
    p.ctxt("CHARACTER EVOLVED -> Graduation gown", 480, 270, "m", GOLD)
    p.ctxt("BTNC: continue to the next stage", 480, 370, "s", LBLUE)
