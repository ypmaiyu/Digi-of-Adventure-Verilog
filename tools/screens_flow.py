"""Opening slides, cutscenes and the ending (open.py, cutscene_1_2.py, cutscene_2_3.py,
cutscene_ending.py). Pictures and moving parts are drawn by rtl/flow/story.v; these
programs only add the words, frames and buttons."""
from uilib import wrap

WHITE, GOLD, GREEN, LBLUE = (255, 255, 255), (255, 230, 120), (150, 255, 170), (170, 200, 255)

C12_LINES = [
    "You cracked the Final Exam door locks and escaped Room CPE1119!",
    "STAGE EVOLUTION: Student Uniform  ->  Workshop Shirt",
    "Next stop: your Engineering Internship. Time to put your hardware skills to work.",
]
C23_SUBS = ["Stage 2 Clear - Internship Complete!", "Received: Graduation Gown", "Character Evolved! Ready for Stage 3."]
CARD_NAMES = {0: ("Fart", "Wing", "Plane"), 1: ("Boat", "Wrench", "Money"), 2: ("Worm", "Flag", "Plug")}
CAREER = {0: ("Green", (80, 200, 105)), 1: ("Yellow", (235, 195, 60)), 2: ("Red", (220, 85, 70))}
ENDINGS = {1: "Fried Grasshopper Seller", 2: "Aircon Technician", 3: "Astronaut", 4: "Noodle Seller",
           5: "Software Engineer", 6: "Lottery Seller", 7: "Fisherman", 8: "Pirate", 9: "Subsea Network Engineer"}


def build_flow(ui):
    # ---------------- opening (open.py) ----------------
    ui.table("T_OPEN_PAGE", [("P%d" % i, "%d / 6" % i) for i in range(1, 7)])
    p = ui.program("OPEN_HINT")
    at = p.if_("C_OPEN_BLINK")
    p.txt("click to continue", 960 - 18 - 17 * 12, 540 - 42, "m", WHITE)
    p.end(at)
    p.sel("T_OPEN_PAGE", "F_OPEN_PAGE", 36, 540 - 42, "m", (230, 230, 230))
    p = ui.program("OPEN_PAGENO")
    p.sel("T_OPEN_PAGE", "F_OPEN_PAGE", 36, 540 - 42, "m", (230, 230, 230))
    p = ui.program("OPEN_ENTER")                     # "ENTER THE ROOM" button, centre (506, 405), 384x54
    at = p.if_("C_OPEN_HOVER")
    p.rect(506 - 192, 405 - 27, 384, 54, (30, 60, 130), border=(255, 215, 90))
    p.ctxt("ENTER THE ROOM", 506, 405 - 13, "l", (255, 215, 90))
    p.end(at)
    at = p.if_("C_OPEN_HOVER", neg=True)
    p.rect(506 - 192, 405 - 27, 384, 54, (18, 28, 60), border=(245, 245, 255))
    p.ctxt("ENTER THE ROOM", 506, 405 - 13, "l", (245, 245, 255))
    p.end(at)
    p.sel("T_OPEN_PAGE", "F_OPEN_PAGE", 36, 540 - 42, "m", (230, 230, 230))

    # ---------------- cutscene 1 -> 2 (single picture, caption box) ----------------
    ui.table("T_C12_LINE", [("L%d" % i, t) for i, t in enumerate(C12_LINES)], wrap_chars=70)
    ui.table("T_C12_STEP", [("S%d" % i, "%d / 3" % (i + 1)) for i in range(3)])
    p = ui.program("C12_BOX")
    p.rect(40, 376, 880, 124, None, border=GOLD)
    p.txt("STAGE 1  ->  STAGE 2", 62, 388, "s", GOLD)
    p.sel("T_C12_LINE", "F_C12_IDX", 62, 418, "m", (245, 245, 250), lh=28)
    at = p.if_("C_C12_PROMPT")
    at2 = p.if_("C_C12_LAST")
    s = "BTNC: Enter Stage 2 >>"
    p.text_c(p.col(900) - len(s), p.row(474, "s"), s, GREEN)
    p.end(at2)
    at2 = p.if_("C_C12_LAST", neg=True)
    s = "BTNC: Next"
    p.text_c(p.col(900) - len(s), p.row(474, "s"), s, GREEN)
    p.end(at2)
    p.end(at)
    p.sel("T_C12_STEP", "F_C12_IDX", 62, 474, "s", (160, 170, 190))

    # ---------------- cutscene 2 -> 3 (three slides + bottom bar) ----------------
    ui.table("T_C23_SUB", [("S%d" % i, t) for i, t in enumerate(C23_SUBS)])
    ui.table("T_C23_STEP", [("S%d" % i, "%d / 3" % (i + 1)) for i in range(3)])
    p = ui.program("C23_BAR")
    p.sel("T_C23_STEP", "F_C23_IDX", 36, 540 - 44, "s", (180, 190, 210))
    p.sel("T_C23_SUB", "F_C23_IDX", 480, 540 - 42, "s", GOLD, center=True)
    at = p.if_("C_C23_PROMPT")
    at2 = p.if_("C_C23_LAST")
    s = "BTNC: Enter Stage 3 >>"
    p.text_c(80 - 1 - len(s), p.row(540 - 44, "s"), s, GREEN)
    p.end(at2)
    at2 = p.if_("C_C23_LAST", neg=True)
    s = "BTNC: Next >>"
    p.text_c(80 - 1 - len(s), p.row(540 - 44, "s"), s, GREEN)
    p.end(at2)
    p.end(at)

    # ---------------- ending: graduation summary (step 0) ----------------
    ui.table("T_END_CAREER", [("C%d" % c, "Career Color: " + CAREER[c][0]) for c in range(3)])
    ui.table("T_END_SLOT", [("C%dP%dN%d" % (c, pos, n), "%s: x%d" % (CARD_NAMES[c][pos], n))
                            for c in range(3) for pos in range(3) for n in range(5)])
    ui.table("T_END_MOST", [("C%dP%dE%d" % (c, pos, e), "Most Picked: %s Card  ->  Ending #%d" % (CARD_NAMES[c][pos], e))
                            for c in range(3) for pos in range(3) for e in [(3, 1, 2), (4, 5, 6), (7, 8, 9)][c][pos:pos + 1]])
    ui.table("T_END_TITLE", [("E%d" % e, "Ending %d/9: %s" % (e, ENDINGS[e])) for e in range(1, 10)])
    p = ui.program("END_GRAD")
    p.ctxt("CONGRATULATIONS, GRADUATE!", 480, 62 - 14, "l", (255, 230, 110))
    p.ctxt("You cleared Stage 3 and officially graduated from CPE!", 480, 104 - 9, "m", (235, 240, 250))
    p.rect(110, 142, 740, 300, None, border=(255, 220, 110))
    p.rect(110 + 28, 142 + 34, 170, 210, None, border=(90, 110, 155))
    p.ctxt("Class of CPE", 110 + 28 + 85, 142 + 34 + 210 + 13, "s", (200, 215, 245))
    rx = 110 + 28 + 170 + 34
    p.txt("YOUR CARD JOURNEY", rx, 142 + 28, "s", (170, 190, 230))
    for c in range(3):
        at = p.if_("C_END_CAR%d" % c)
        p.sel("T_END_CAREER", "F_END_CAREER", rx, 142 + 58, "m", CAREER[c][1])
        p.end(at)
    for pos in range(3):
        x = rx + pos * 158 - 9
        for top, colr, edge in ((True, (255, 235, 140), (255, 225, 110)), (False, (210, 215, 230), (75, 85, 115))):
            at = p.if_("C_END_TOP%d" % pos, neg=not top)
            p.rect(x, 142 + 102, 156, 140, None, border=edge)
            p.sel("T_END_SLOT", "F_END_SLOT%d" % pos, x + 78, 142 + 102 + 140 - 30, "s", colr, center=True)
            p.end(at)
    p.sel("T_END_MOST", "F_END_MOST", rx, 142 + 300 - 38, "s", (150, 255, 175))
    at = p.if_("C_END_BLINK")
    p.ctxt("BTNC: Reveal Your Ending Career >>", 480, 540 - 56 - 9, "m", GREEN)
    p.end(at)

    # ---------------- ending: reveal (step 1) + "play again?" ----------------
    p = ui.program("END_PILL")
    p.ctxt("BTNC: Finish Options   |   BTNL: Summary", 480, 540 - 42 + 5, "tiny", (230, 235, 245), bg=(12, 14, 20))
    p = ui.program("END_CONFIRM")
    bx, by, bw, bh = 168, 172, 624, 196
    p.rect(bx, by, bw, bh, (18, 22, 34), border=(255, 225, 110))
    p.ctxt("RETURN TO THE BEGINNING?", bx + bw // 2, by + 42 - 9, "m", (255, 230, 120))
    p.ctxt("Leave your ending screen and start a new game?", bx + bw // 2, by + 78 - 7, "s", (220, 225, 240))
    for (x, label, idx, fill, hi) in ((280, "Keep Viewing", 0, (48, 86, 130), (140, 220, 255)),
                                      (495, "Play Again", 1, (120, 52, 52), (255, 160, 130))):
        at = p.if_("C_END_CHOICE%d" % idx)
        p.rect(x, 290, 185, 48, fill, border=(255, 230, 120))
        p.ctxt(label, x + 92, 290 + 24 - 7, "s", hi)
        p.end(at)
        at = p.if_("C_END_CHOICE%d" % idx, neg=True)
        p.rect(x, 290, 185, 48, (34, 38, 52), border=(90, 98, 125))
        p.ctxt(label, x + 92, 290 + 24 - 7, "s", (210, 215, 230))
        p.end(at)
    p.ctxt("BTNL / BTNR: Select   |   BTNC: Confirm", bx + bw // 2, by + bh - 20 - 5, "tiny", (175, 185, 210))
    p = ui.program("END_BAR")
    p.sel("T_END_TITLE", "F_END_NUM", 16, 540 + 14, "s", GOLD)


def write_confetti(path):
    """cutscene_ending.Game.confetti and the sine table, as Verilog functions (view pixels)."""
    import math
    cols = [(255, 220, 90), (120, 220, 255), (140, 245, 160), (255, 140, 160), (210, 160, 255)]
    with open(path, "w") as f:
        f.write("// generated by ui_compiler.py from cutscene_ending.py (confetti) - do not edit\n")
        f.write("// confetti(i) = {x0_view[9:0], y0_ui[9:0], spd_ui[6:0], size_view[2:0], colour[11:0], phase[7:0]}\n")
        f.write("function [49:0] confetti;\n  input [5:0] i;\n  begin\n    case (i)\n")
        for i in range(42):
            x0, y0 = (i * 73) % 960, (i * 41) % 540
            spd = 28 + (i * 19) % 45
            sz = ((i * 7) % 5) + 3
            c = cols[i % 5]
            col = (round(c[0] / 17) << 8) | (round(c[1] / 17) << 4) | round(c[2] / 17)
            ph = int(round((y0 % (2 * math.pi)) / (2 * math.pi) * 256)) % 256
            f.write("      6'd%d: confetti = {10'd%d, 10'd%d, 7'd%d, 3'd%d, 12'h%03X, 8'd%d};\n"
                    % (i, round(x0 * 2 / 3), y0, spd, max(1, round(sz * 2 / 3)), col, ph))
        f.write("      default: confetti = 50'd0;\n    endcase\n  end\nendfunction\n")
        f.write("// sin_tab(k) = round(sin(2*pi*k/256) * 14 UI px * 2/3), signed\n")
        f.write("function signed [4:0] sin_tab;\n  input [7:0] k;\n  begin\n    case (k)\n")
        for k in range(256):
            v = int(round(math.sin(2 * math.pi * k / 256) * 14 * 2 / 3))
            f.write("      8'd%d: sin_tab = %s5'sd%d;\n" % (k, "-" if v < 0 else "", abs(v)))
        f.write("      default: sin_tab = 5'sd0;\n    endcase\n  end\nendfunction\n")
