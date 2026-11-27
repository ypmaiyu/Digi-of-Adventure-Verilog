"""Stage 1 (Final Exam) screens - a line-by-line port of stage1_demo.py draw_* functions.
Coordinates are the Pygame ones (960x540 UI; close-ups use the 640 px subsurface at x=160)."""
from uilib import wrap

WHITE, GOLD, LBLUE, GREEN = (255, 255, 255), (255, 230, 120), (170, 200, 255), (150, 255, 170)
PANEL, EDGE = (20, 22, 30), (120, 130, 170)
OKC, BADC, NEUT = (110, 255, 145), (255, 105, 105), (255, 225, 120)

# ---------------- text data copied from stage1_demo.py ----------------
HINTS = {
    "P1": "10",
    "P2": "Circle the 1s in the biggest groups you can. Two groups are enough.",
    "P3": "De Morgan",
    "P4": "00001100",
    "P5": "It takes greater faith to dance in the dark than to rest in light.",
}
INTRO_LINES = [
    "Hey! Our Final Exam in Room CPE1119 is starting right now.",
    "To pass the exam, you must solve all 5 puzzles around the classroom to uncover the password for the exit door.",
    "Good luck!",
]
SEARCH = ["WHITEBOARD", "PAPER", "LAPTOP 1", "LAPTOP 2", "PROJECTOR SCREEN", "TEACHER COMPUTER",
          "LIGHT SWITCH", "EXIT DOOR"]
OBJ_TITLES = ["Whiteboard", "Paper on the cabinet", "Laptop 1", "Laptop 2", "Projector screen",
              "Teacher computer", "Light switch", "Exit door"]

P_OK = ["The base-conversion answer is correct. Puzzle 1 is complete.",
        "Your K-map expression is correct. You can use this to solve the next puzzle.",
        "The NAND circuit produces the correct truth table. Puzzle 3 is complete.",
        "The two's-complement value is correct. Puzzle 4 is complete.",
        "ACCESS GRANTED. The login passcode is correct. Puzzle 5 is complete."]
P_BAD = ["The base-conversion answer is incorrect. Check your calculation and try again.",
         "Your K-map expression is not correct. Check your variables and terms, then try again.",
         "The NAND circuit output does not match the required truth table. Check the connections and try again.",
         "The binary value is incorrect. Check the two's-complement conversion and try again.",
         "ACCESS DENIED. The passcode is incorrect. Check the letters and try again."]


def two_lines(s, n=50):
    return "\n".join(wrap(s, n)[:2])           # draw_closeup shows the first 2 wrapped lines only


def card_descs_s1():
    """Every text grant() can return in Stage 1 (T_CARD_DESC rows)."""
    d = [("NONE", "")]
    for k, v in HINTS.items():
        d.append(("HINT_" + k, v))
    d += [("NO_HINT", "No hint this time. Keep going!"),
          ("UNDO_NONE", "Nothing to undo right now."),
          ("UNDO_P4", "Puzzle 4 was undone. Solve it again!"),
          ("ARMOR", "Blocks the next wrong code penalty."),
          ("SLOW", "You walk slower for 10 seconds."),
          ("FREEZE", "You are frozen in place for 10 seconds."),
          ("BOOST", "Saved for later stages."),
          ("SHARD_FORGE", "2 shards forged 1 Armor!"),
          ("SHARD_HALF", "Armor Shard 1 / 2 (saved for later).")]
    return d


def build_s1(ui):
    cm = [("NONE", "")]
    for i in range(5):
        cm.append(("OK%d" % (i + 1), two_lines("CORRECT! " + P_OK[i])))
        cm.append(("BAD%d" % (i + 1), two_lines("INCORRECT! " + P_BAD[i])))
    for t in range(3):
        cm.append(("TERM%d" % (t + 1), two_lines("Stored in Term%d. Continue setting the other terms, then press BTNR to check." % (t + 1))))
    cm.append(("NOTERMS", two_lines("INCORRECT! No terms have been stored yet. Please create your K-map expression first.")))
    cm.append(("LOCK1", "LOCK 1 OPEN. Now the 5-digit lock."))
    cm.append(("WRONG", "WRONG CODE"))
    ui.table("T_S1_CMSG", cm)
    ui.table("T_S1_INTRO", [("L%d" % i, t) for i, t in enumerate(INTRO_LINES)], wrap_chars=60)
    ui.table("T_S1_STEP", [("S%d" % i, "%d / %d" % (i + 1, len(INTRO_LINES))) for i in range(len(INTRO_LINES))])
    ui.table("T_S1_SEARCH", [("O%d" % i, " [SEARCH : %s] " % n) for i, n in enumerate(SEARCH)])
    notes = [("NONE", ""), ("P1", "P1 correct answer: A = 6"), ("P2A", "P2 correct answer: F = AB + CD"),
             ("P2B", "P2 correct answer: F = CD + AB"),
             ("P3", "P3 correct circuit: NAND-only output matches the K-map."),
             ("P4", "P4 correct answer: 11110100 (unsigned 244 / signed -12)."),
             ("P5", "P5 correct login passcode: CPE")]
    ui.table("T_S1_NOTE", [(k, ("- " + t) if t else "") for k, t in notes], wrap_chars=40)
    ui.table("T_S1_HINTSEEN", [("NONE", "")] + [(k, "- " + v) for k, v in HINTS.items()], wrap_chars=40)
    ui.table("T_S1_DOORHDR", [("L1", "LOCK 1 of 2  (2 digits)"), ("L2", "LOCK 2 of 2  (5 digits)")])
    ui.table("T_S1_TITLE", [("O%d" % i, t.upper()) for i, t in enumerate(OBJ_TITLES)])

    # ---------------- [SEARCH : X] label above the player (draw_interaction_hint) ----------------
    p = ui.program("S1_SEARCH")
    at = p.if_("C_S1_NEAR")
    p.org("F_S1_LBL_COL", "F_S1_LBL_ROW")
    p.strsel_c(0, 0, "T_S1_SEARCH", "F_S1_NEAR", (225, 230, 240), center=True, bg=(15, 18, 25))
    p.org()
    p.end(at)

    # ---------------- intro talk with the TA (draw_intro_talk) ----------------
    p = ui.program("S1_INTRO")
    # box fills are drawn by the line engine (so the TA portrait picture can sit inside);
    # the text layer only adds the borders and the words
    p.rect(40, 376, 880, 128, None, border=GOLD)
    p.rect(56, 390, 100, 100, None, border=(110, 125, 165))
    tx = 56 + 100 + 18
    p.txt("TA", tx, 388, "m", GOLD)
    p.sel("T_S1_INTRO", "F_S1_INTRO", tx, 418, "m", (245, 245, 250), lh=24)
    p.sel("T_S1_STEP", "F_S1_INTRO", tx, 480, "s", (160, 170, 190))
    at = p.if_("C_S1_INTRO_LAST")
    s = "BTNC: start exam >>"
    p.text_c(p.col(900) - len(s), p.row(480, "s"), s, (150, 255, 170))
    p.end(at)
    at = p.if_("C_S1_INTRO_LAST", neg=True)
    s = "BTNC: next >>"
    p.text_c(p.col(900) - len(s), p.row(480, "s"), s, (170, 200, 255))
    p.end(at)

    # ---------------- help (draw_help) ----------------
    p = ui.program("S1_HELP")
    p.ox = 160
    p.rect(30, 60, 580, 420, PANEL, border=EDGE)
    p.ctxt("HOW TO PLAY", 320, 74, "l")
    rows = [("Move", "BTNU / BTND / BTNL / BTNR"), ("Interact / confirm", "BTNC (tap)"),
            ("Back", "BTNC (hold for 0.8 s)"), ("Puzzle inputs", "SW0-SW7"), ("Notebook", "SW14 (toggle)"),
            ("Help", "SW15 (toggle)")]
    for i, (a, b) in enumerate(rows):
        p.txt(a, 54, 128 + i * 30, "s", GOLD)
        p.txt(b, 250, 128 + i * 30, "s")
    p.wraptxt("Approach an object and press BTNC. If nothing happens, it is scenery.", 54, 330, 530, "m", LBLUE)
    p.ctxt("BTNC: start", 320, 442, "m", GREEN)

    # ---------------- close-up frame (draw_closeup) ----------------
    p = ui.program("S1_CU_FRAME")
    p.ox = 160
    p.rect(0, 0, 640, 44, (70, 74, 90))
    p.strsel_c(p.col(16), 2, "T_S1_TITLE", "F_S1_OBJ", WHITE, big=True)
    p.rect(0, 480, 640, 44, (40, 44, 60))
    p.txt("Back: hold BTNC for 0.8 s", 16, 504, "tiny", (140, 150, 180))
    for cond, col in (("C_S1_FB_OK", OKC), ("C_S1_FB_BAD", BADC), ("C_S1_FB_NONE", NEUT)):
        at = p.if_(cond)
        p.sel("T_S1_CMSG", "F_S1_CMSG", 16, 434, "m", col, lh=24)
        p.end(at)

    def foot(p, text):
        p.txt(text, 16, 484, "s", LBLUE)

    # ---------------- whiteboard / puzzle 1 ----------------
    p = ui.program("S1_CU_WHITEBOARD")
    p.ox = 160
    ink = (30, 40, 130)
    p.rect(40, 56, 560, 376, (240, 240, 235))
    at = p.if_("C_S1_PAGE0")
    lines = ["ROOM CPE1119 - FINAL EXAM", "attendance sheet", "", "registered ........ 0x2A",
             "absent ............ 0b10011", "sick leave ........ 0o21", "", "sitting the exam = ?"]
    for i, l in enumerate(lines):
        if l:
            p.txt(l, 70, 78 + i * 38, "mono_l", ink)
    foot(p, "BTNC: next page")
    p.end(at)
    at = p.if_("C_S1_PAGE0", neg=True)
    for i, l in enumerate(["margin notes:", "weights   128 64 32 16 8 4 2 1",
                           "hex  A=10 B=11 C=12 D=13 E=14 F=15", "octal: digits are 8s and 1s"]):
        p.txt(l, 70, 70 + i * 26, "mono", ink)
    p.rect(70, 190, 500, 224, (60, 60, 70))
    p.txt("HEAD-COUNT DIAL  (switches SW3..SW0)", 90, 202, "s")
    for k in range(4):
        i = 3 - k
        cx = 136 + k * 84
        c = p.col(cx)
        r = p.rowr(280)
        for on, colr in ((True, (255, 220, 60)), (False, (90, 90, 90))):
            a2 = p.if_("C_SW%d" % i, neg=not on)
            for q, (dc, dr) in enumerate(((-2, -2), (0, -2), (-2, 0), (0, 0))):
                p.char_c(c + dc, r + dr, 0x10 + q, colr, big=True)
            p.end(a2)
        p.ctxt(str(8 >> k), cx, 316, "m")
    p.txt("=", 450, 262, "l")
    p.field_c(p.col(450) + 3, p.row(262, "l"), "F_S1_P1VAL", WHITE, 3, big=True)
    a2 = p.if_("C_S1_DONE0")
    p.txt("LOGGED: A = 6", 90, 366, "m", GOLD)
    p.end(a2)
    foot(p, "ANSWER: set SW3-SW0, then BTNC")
    p.end(at)

    # ---------------- paper / puzzle 2 (K-map) ----------------
    GRAY = [0, 1, 3, 2]
    P2_TRUTH = 0xF888

    def kmap(p, x, y, cell, ink):
        p.txt("AB\\CD", x, y + 4, "s", ink)
        cw = max(3, int(round(cell * 2 / 3 / 8)))
        c0 = p.col(x + cell)
        r0 = p.rowr(y + cell)
        for c in range(4):
            p.text_c(c0 + c * cw + cw // 2, p.row(y + 4, "s"), "%d%d" % (GRAY[c] >> 1, GRAY[c] & 1), ink)
        for r in range(4):
            p.text_c(p.col(x + 6), r0 + r * cw + cw // 2, "%d%d" % (GRAY[r] >> 1, GRAY[r] & 1), ink)
            for c in range(4):
                m = (GRAY[r] << 2) | GRAY[c]
                p.rect_c(c0 + c * cw, r0 + r * cw, cw, cw, None, border=ink)
                p.text_c(c0 + c * cw + cw // 2, r0 + r * cw + cw // 2, str((P2_TRUTH >> m) & 1), ink, center=False)

    p = ui.program("S1_CU_PAPER")
    p.ox = 160
    ink = (40, 40, 40)
    p.rect(40, 56, 560, 366, (245, 240, 220))
    at = p.if_("C_S1_PAGE0")
    p.txt("SENSOR FAIL LOG   (1 = failed)", 70, 68, "m", ink)
    p.txt("rows: A B   cols: C D   (Sum of Products)", 70, 94, "s", ink)
    kmap(p, 70, 122, 52, ink)
    p.txt("F =", 400, 230, "l", ink)
    p.rect(450, 190, 150, 110, None, dither=(110, 70, 30))        # coffee stain (dithered)
    foot(p, "BTNC: next page")
    p.end(at)
    at = p.if_("C_S1_PAGE0", neg=True)
    kmap(p, 56, 70, 44, ink)
    for i in range(3):
        y = 90 + i * 46
        a2 = p.if_("C_S1_P2CUR%d" % i)
        p.rect(310, y - 6, 270, 38, GOLD)
        p.end(a2)
        p.txt("Term%d:" % (i + 1), 324, y, "m", ink)
        p.field_c(p.col(324) + 7, p.row(y), "F_S1_TERM%d" % i, ink, 12)
    p.txt("switches say:", 310, 240, "m", (30, 80, 160))
    p.fld("F_S1_SWTERM", 310, 264, "m", (30, 80, 160), 12)
    p.txt("SW7-4: which letters", 310, 290, "s", ink)
    p.txt("       (A B C D)", 310, 310, "s", ink)
    p.txt("SW3-0: 1 = plain,", 310, 330, "s", ink)
    p.txt("       0 = inverted", 310, 350, "s", ink)
    a2 = p.if_("C_S1_DONE1")
    p.txt("LOGGED: F =", 70, 380, "m", (30, 80, 160))
    p.field_c(p.col(70) + 12, p.row(380), "F_S1_P2EQ", (30, 80, 160), 16)
    p.end(a2)
    foot(p, "BTNU/BTND slot | BTNC store | BTNR confirm answer")
    p.end(at)

    # ---------------- laptop 1 / puzzle 3 (NAND editor) ----------------
    p = ui.program("S1_CU_NAND")
    p.ox = 160
    g = (110, 255, 130)
    hl = (255, 255, 120)
    p.rect(40, 60, 560, 360, (10, 20, 10))
    at = p.if_("C_S1_PAGE0")
    lines = ["SYSTEM TERMINAL - LAB 01", "", "Status: Spec match required", "Task: Build F from puzzle on cabinet as a",
             "      minimal combinational circuit", "Constraint: 74HC00 quad NAND gates only.",
             "            G(n) = Gate(n)"]
    for i, l in enumerate(lines):
        if l:
            p.txt(l, 56, 76 + i * 32, "mono", g)
    foot(p, "BTNC: open circuit editor")
    p.end(at)
    at = p.if_("C_S1_PAGE0", neg=True)
    for k in range(4):
        y = 74 + k * 44
        for j in range(2):
            f = 2 * k + j
            for sel, colr, mark in ((True, hl, "> "), (False, g, "  ")):
                a2 = p.if_("C_S1_P3CUR%d" % f, neg=not sel)
                p.txt(mark + "G%d in%d:" % (k + 1, j + 1), 64 + j * 260, y, "mono", colr)
                p.field_c(p.col(64 + j * 260) + 11, p.row(y, "mono"), "F_S1_P3SRC%d" % f, colr, 2)
                p.end(a2)
    for sel, colr, mark in ((True, hl, "> "), (False, g, "  ")):
        a2 = p.if_("C_S1_P3CUR8", neg=not sel)
        p.txt(mark + "F = output of: G", 64, 256, "mono", colr)
        p.field_c(p.col(64) + 18, p.row(256, "mono"), "F_S1_P3OUT", colr, 1)
        p.end(a2)
    p.txt("your F:   ", 64, 320, "tiny", g)
    p.field_c(p.col(64) + 10, p.row(320, "tiny"), "F_S1_P3BITS", g, 19)
    foot(p, "BTNL/R: field | BTNU/D: src | BTNC: save")
    p.end(at)

    # ---------------- laptop 2 / puzzle 4 ----------------
    p = ui.program("S1_CU_TWOS")
    p.ox = 160
    g = (130, 200, 255)
    p.rect(40, 60, 560, 360, (10, 10, 25))
    at = p.if_("C_S1_PAGE0")
    lines = ["SYSTEM KERNEL CONSOLE", "", "Target register: penalty_reg", "Current decimal value: 12",
             "Operation: Invert sign using two's complement", "", "READY FOR PATCH INPUT..."]
    for i, l in enumerate(lines):
        if l:
            p.txt(l, 56, 76 + i * 34, "mono", g)
    foot(p, "BTNC: open patch console")
    p.end(at)
    at = p.if_("C_S1_PAGE0", neg=True)
    p.txt("penalty_reg patch value:", 70, 90, "m", g)
    p.field_c(p.col(70), p.row(130, "l"), "F_S1_SW8BITS", (255, 255, 120), 8, big=True)
    p.txt("unsigned", 70, 180, "m", g)
    p.field_c(p.col(70) + 9, p.row(180), "F_S1_P4U", g, 3)
    p.txt("signed", 70 + 14 * 12, 180, "m", g)
    p.field_c(p.col(70) + 21, p.row(180), "F_S1_P4S", g, 4)
    foot(p, "ANSWER: set SW7-SW0, then BTNC")
    p.end(at)

    # ---------------- projector screen / puzzle 5 clue (letters rendered directly) ----------------
    p = ui.program("S1_CU_SCREEN")
    p.ox = 160
    at = p.if_("C_S1_LIGHTS")
    p.rect(40, 60, 560, 360, (235, 235, 230))
    p.ctxt("No Signal", 320, 230, "s", (150, 150, 145))
    p.end(at)
    at = p.if_("C_S1_LIGHTS", neg=True)
    p.rect(40, 60, 560, 360, (15, 20, 30))
    p.ctxt("PROJECTOR SLIDE: LETTER MASTERMIND", 320, 60, "s", (130, 200, 255))
    p.rect(50, 88, 480, 30, (40, 50, 70))
    p.txt("Letter Sequence", 60, 94, "tiny", GOLD)
    p.txt("Letters", 345, 94, "tiny", GOLD)
    p.txt("Pos.", 465, 94, "tiny", GOLD)
    clues = [("F   E   C", "2", "0"),
             ("F   C   X", "1", "0"),
             ("C   A   P", "2", "1"),
             ("P   A   F", "1", "0"),
             ("A   E   F", "1", "0")]
    for idx, (seq, ca, cp) in enumerate(clues):
        y = 122 + idx * 35
        p.rect(50, y, 480, 33, (25, 32, 45) if idx % 2 == 0 else (20, 26, 38))
        p.txt(seq, 108, y + 8, "m", WHITE)
        p.ctxt(ca, 365, y + 8, "s", (150, 255, 150))
        p.ctxt(cp, 485, y + 8, "s", (255, 220, 100))
    p.ctxt("Deduce the secret 3-letter code from clues.", 320, 316, "tiny", (180, 220, 180))
    foot(p, "Use the 3-letter code ")
    p.end(at)

    # ---------------- light switch ----------------
    p = ui.program("S1_CU_LIGHTSW")
    p.ox = 160
    p.rect(260, 110, 120, 200, (200, 200, 200))
    at = p.if_("C_S1_LIGHTS")
    p.rect(290, 130, 60, 70, (90, 200, 90))
    p.ctxt("LIGHTS ON", 320, 340, "m")
    p.end(at)
    at = p.if_("C_S1_LIGHTS", neg=True)
    p.rect(290, 220, 60, 70, (200, 80, 80))
    p.ctxt("LIGHTS OFF", 320, 340, "m")
    p.end(at)
    foot(p, "BTNC: flip the switch")

    # ---------------- exit door (two layer password) ----------------
    p = ui.program("S1_CU_DOOR")
    p.ox = 160
    p.rect(240, 56, 160, 230, (120, 85, 55))
    p.sel("T_S1_DOORHDR", "F_S1_DOORL", 320, 298, "m", WHITE, center=True)
    for n, cond in ((2, "C_S1_DOORL1"), (5, "C_S1_DOORL2")):
        at = p.if_(cond)
        x0 = 320 - n * 70 // 2
        for i in range(n):
            x = x0 + i * 70 + 5
            for sel, colr in ((True, GOLD), (False, (200, 200, 200))):
                a2 = p.if_("C_S1_DCUR%d" % i, neg=not sel)
                p.rect(x, 332, 60, 64, colr)
                p.end(a2)
            p.field_c(p.col(x + 30) - 1, p.row(346, "l"), "F_S1_DIG%d" % i, (20, 20, 20), 1, big=True)
        p.end(at)
    foot(p, "BTNU/BTND digit | BTNL/BTNR box | BTNC confirm")

    # ---------------- teacher computer (login, then manual pages) ----------------
    p = ui.program("S1_CU_PC")
    p.ox = 160
    c = (160, 200, 255)
    p.rect(40, 60, 560, 360, (15, 25, 50))
    at = p.if_("C_S1_DONE4", neg=True)
    p.txt("PROFESSOR TERMINAL LOGIN", 70, 75, "mono", c)
    p.txt("Enter 3-letter passcode (A-Z):", 70, 115, "s", c)
    for i in range(3):
        x = 180 + i * 90
        for sel, colr in ((True, GOLD), (False, (60, 75, 110))):
            a2 = p.if_("C_S1_P5CUR%d" % i, neg=not sel)
            p.rect(x, 150, 70, 70, colr)
            p.end(a2)
        p.field_c(p.col(x + 35) - 1, p.row(168, "l"), "F_S1_P5L%d" % i, WHITE, 1, big=True)
    p.txt("Match projector clues to unlock terminal", 70, 250, "tiny", (180, 220, 180))
    foot(p, "BTNU/BTND letter (A-Z) | BTNL/BTNR box | BTNC enter")
    p.end(at)
    at = p.if_("C_S1_DONE4")
    a2 = p.if_("C_S1_PAGE0")
    p.txt("Welcome, prof.", 70, 90, "mono_l", c)
    p.txt("[ door_manual.txt ]", 70, 150, "mono_l", GOLD)
    foot(p, "BTNU/BTND or BTNC: open file")
    p.end(a2)
    a2 = p.if_("C_S1_PAGE1")
    lines = ["DOOR - LAYER 1  (2 digits)", "1. Take LAST letter of login password.",
             "2. Find it in the table (values are HEX).", "3. Key in its DECIMAL value.", "",
             "A 41  B 42  C 43  D 44  E 45  F 46  G 47", "H 48  I 49  J 4A  K 4B  L 4C  M 4D  N 4E",
             "O 4F  P 50  Q 51  R 52  S 53  T 54  U 55", "V 56  W 57  X 58  Y 59  Z 5A"]
    for i, l in enumerate(lines):
        if l:
            p.txt(l, 56, 74 + i * 33, "mono", c)
    foot(p, "BTNU/BTND: page")
    p.end(a2)
    a2 = p.if_("C_S1_PAGE2")
    lines = ["DOOR - LAYER 2  (5 digits)", "A = whiteboard dial result",
             "B = report code from cabinet + laptop 1", "    (Number of bit 1)", "C = laptop 2 receipt (Number of bit 1)",
             "Step 1: S = A + B + C.  Row: A B C S", "        (S has two digits -> 5 digits)",
             "Step 2: new digit 1 = old position 4,", "        then old 2, 5, 1, 3.",
             "Example: row 2 4 6 8 9 -> 8 4 9 2 6"]
    for i, l in enumerate(lines):
        p.txt(l, 56, 72 + i * 30, "mono", c)
    foot(p, "BTNU/BTND: page")
    p.end(a2)
    p.end(at)

    # ---------------- notebook (SW14) ----------------
    p = ui.program("S1_NOTEBOOK")
    p.ox = 160
    p.rect(40, 44, 560, 440, PANEL, border=EDGE)
    p.ctxt("NOTEBOOK  (SW14 to close)", 320, 56, "m")
    p.txt("Answers Logged: A =", 64, 92, "s", GOLD)
    p.field_c(p.col(64) + 20, p.row(92, "s"), "F_S1_ANS_A", GOLD, 1)
    p.text_c(p.col(64) + 24, p.row(92, "s"), "B =", GOLD)
    p.field_c(p.col(64) + 28, p.row(92, "s"), "F_S1_ANS_B", GOLD, 1)
    p.text_c(p.col(64) + 32, p.row(92, "s"), "C =", GOLD)
    p.field_c(p.col(64) + 36, p.row(92, "s"), "F_S1_ANS_C", GOLD, 1)
    p.txt("Logged Actions & Clues:", 64, 128, "s", LBLUE)
    p.setcur(p.row(150, "s"))
    for k in range(6):
        p.strsel_c(p.col(64), 0, "T_S1_NOTE", "F_S1_NOTE%d" % k, (230, 230, 230), flow=True, lstep=1)
    p.text_c(p.col(64), 0, "Hints Used:", LBLUE, flow=True, lstep=1)
    for k in range(3):
        p.strsel_c(p.col(64), 0, "T_S1_HINTSEEN", "F_S1_HINTSEEN%d" % k, (230, 230, 230), flow=True, lstep=1)

    # ---------------- "answer saved" guide ----------------
    p = ui.program("S1_NBGUIDE")
    p.ox = 160
    p.rect(12, 165, 616, 190, PANEL, border=EDGE)
    p.ctxt("ANSWER SAVED TO NOTEBOOK", 320, 190, "l", GREEN)
    p.ctxt("Your correct answer has been recorded.", 320, 240, "m")
    p.ctxt("Flip SW14 to open the Notebook and view it.", 320, 278, "m", GOLD)
    p.ctxt("Gameplay will continue after you open it.", 320, 318, "s", LBLUE)

    # ---------------- out of hearts / stage clear ----------------
    p = ui.program("S1_OVER")
    p.ctxt("OUT OF HEARTS", 480, 220, "l", (255, 90, 90))
    p.ctxt("Restarting Stage 1...", 480, 270, "m")
    p = ui.program("S1_CLEAR")
    p.ctxt("STAGE 1 CLEAR - YOU PASSED THE EXAM!", 480, 160, "l", GREEN)
    p.txt("Hearts left:", 480 - 6 * 12, 220, "m")
    p.field_c(p.col(480) + 7, p.row(220), "F_HEARTS", WHITE, 1)
    p.ctxt("CHARACTER EVOLVED -> Lab coat", 480, 270, "m", GOLD)
    p.ctxt("BTNC: continue to the next stage", 480, 370, "s", LBLUE)
