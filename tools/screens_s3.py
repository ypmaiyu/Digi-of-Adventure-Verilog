"""Stage 3 (graduation obby) HUD and overlays - port of onlystage_3/hud.py.
hud.py draws on the 640x360 frame, so coordinates here are written in that space and
multiplied by 1.5 to reach the 960x540 UI space used by uilib."""
from uilib import wrap
import os, sys

IVORY, NIGHT, GOLD, MINT, INK, PARCH = (231, 250, 255), (8, 40, 61), (117, 222, 242), (167, 239, 247), (18, 62, 85), (205, 238, 247)
K = 1.5


def F(v):
    return v * K


def questions():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    if os.path.isdir(os.path.join(root, "onlystage_3")):
        sys.path.insert(0, root)
        import onlystage_3.settings as C
        return C.QUESTIONS, C.ROUTES
    import ui_fallback as fb
    return fb.S3_QUESTIONS, fb.S3_ROUTES


MESSAGES = [
    ("NONE", ""),
    ("NEW_GAME", "New game"),
    ("STAGE2", "Stage 2   /   S4 to CB2"),
    ("STAGE3", "Stage 3   /   N17 to N16"),
    ("TIME_UP", "Time up!  Skill restored"),
    ("FELL", "Fell!  Skill restored"),
    ("SPLASH", "Splash!  Skill restored"),
    ("USE_CLOAK", "Use Cloak when a reporter is following."),
    ("PICK_TEA", "Pick up the milk tea!"),
    ("REPORTER", "A reporter is coming to interview you!"),
    ("TEA", "Tea Time Awakening! Superyasai Power: Phase Through Every Obstacle!"),
    ("NEAR1", "Just a little further to Red Building! You've got this!"),
    ("NEAR2", "Almost at CB2! Keep pushing!"),
    ("NEAR3", "Graduation Ceremony is right ahead! Hang in there!"),
    ("HIT_BLOCK", "Hit the ? block, then collect the milk tea."),
    ("RETRY", "Checkpoint restart  /  Skill restored"),
]


def build_s3(ui):
    Q, ROUTES = questions()
    ui.table("T_S3_MSG", [(k, (" %s " % t) if t else "") for k, t in MESSAGES])
    ui.table("T_S3_Q", [("Q%dL%d" % (i, j), q[j]) for i, q in enumerate(Q) for j in range(2)])
    ui.table("T_S3_FROM", [("S%d" % n, ROUTES[n][0]) for n in (1, 2, 3)])
    ui.table("T_S3_TO", [("S%d" % n, ROUTES[n][1]) for n in (1, 2, 3)])
    ui.table("T_S3_ABILITY", [("CLOAK", "CLOAK"), ("PHASE", "PHASE")])
    ui.table("T_S3_STATUS", [("READY", "READY"), ("USED", "USED")] + [("S%d" % i, "%dS" % i) for i in range(1, 6)])

    # ---------------- clock, skill panel, route bar (clock_and_skill, route_bar) ----------------
    p = ui.program("S3_HUD")
    p.rect(F(20), F(21) - 84, F(96), F(26), None)                        # (plate drawn by the line engine)
    p.text_c(6, 3, "x", IVORY)
    p.field_c(8, 3, "F_S3_TIME", IVORY, 3, big=True)
    p.strsel_c(int(541 / 8), 3, "T_S3_ABILITY", "F_S3_ABILITY", GOLD)
    for st, col in (("C_S3_USED", (101, 124, 140)), ("C_S3_READY", IVORY), ("C_S3_ACTIVE", IVORY)):
        at = p.if_(st)
        p.strsel_c(int(541 / 8), 4, "T_S3_STATUS", "F_S3_STATUS", col, big=True)
        p.end(at)
    # route bar: start label, percent, end label (segments are line-engine fills)
    p.strsel_c(int(144 / 8 + 0.5), int(341 / 8 + 0.5) - 1, "T_S3_FROM", "F_S3_STAGE", GOLD)
    p.strsel_c(int(449 / 8 + 0.5) - 1, int(341 / 8 + 0.5) - 1, "T_S3_TO", "F_S3_STAGE", GOLD)
    p.field_c(int(499 / 8 + 0.5) - 3, int(344 / 8 + 0.5) - 1, "F_S3_PCT", IVORY, 4)

    # ---------------- notice plate (g.notice > 0) ----------------
    p = ui.program("S3_NOTICE")
    p.strsel_c(40, int(309 / 8 + 0.5) - 1, "T_S3_MSG", "F_S3_MSG", INK, center=True, bg=PARCH)

    # ---------------- reporter interview (interview_card) ----------------
    p = ui.program("S3_INTERVIEW")
    p.rect(F(42), F(229), F(556), F(93), PARCH, border=(170, 223, 235))
    p.text_c(int(156 / 8 + 0.5) - 6, int(222 / 8 + 0.5), " CPE REPORTER ", (231, 250, 255), bg=(32, 100, 130))
    p.strsel_c(40, int(265 / 8 + 0.5) - 1, "T_S3_Q", "F_S3_QL0", INK, center=True)
    p.strsel_c(40, int(288 / 8 + 0.5) - 1, "T_S3_Q", "F_S3_QL1", INK, center=True)

    # ---------------- modal: paused / stage clear / win (modal) ----------------
    p = ui.program("S3_MODAL")
    p.rect(F(94), F(111), F(452), F(139), PARCH, border=(170, 223, 235))
    for cond, title in (("C_S3_PAUSE", "  PAUSED  "), ("C_S3_CLEARMODE", " STAGE CLEAR "), ("C_S3_WIN", " STAGE CLEAR ")):
        at = p.if_(cond)
        p.text_c(40, int(100 / 8 + 0.5), title, (231, 250, 255), big=True, center=True, bg=(32, 100, 130))
        p.end(at)
    at = p.if_("C_S3_PAUSE")
    p.strsel_c(40, int(171 / 8 + 0.5) - 1, "T_S3_ROUTE", "F_S3_STAGE", INK, center=True)
    p.text_c(40, int(225 / 8 + 0.5), "BTND TO RESUME", (23, 71, 94), center=True)
    p.end(at)
    at = p.if_("C_S3_CLEAR1")
    p.text_c(40, int(157 / 8 + 0.5) - 1, "Wissawa Wattana Building (S4)", INK, center=True)
    p.text_c(40, int(192 / 8 + 0.5) - 1, "Next stop: Classroom Building 2", INK, center=True)
    p.text_c(40, int(225 / 8 + 0.5), "NEXT   S4 / CB2", (23, 71, 94), center=True)
    p.end(at)
    at = p.if_("C_S3_CLEAR2")
    p.text_c(40, int(157 / 8 + 0.5) - 1, "Classroom Building 2", INK, center=True)
    p.text_c(40, int(189 / 8 + 0.5) - 1, "Next stop: Graduation at N16", INK, center=True)
    p.text_c(40, int(225 / 8 + 0.5), "NEXT   N17 / N16", (23, 71, 94), center=True)
    p.end(at)
    at = p.if_("C_S3_WIN")
    p.text_c(40, int(157 / 8 + 0.5) - 1, "Congratulations, graduate!", INK, center=True)
    p.text_c(40, int(192 / 8 + 0.5) - 1, "You've reached LX for your Graduation Ceremony", INK, center=True)
    p.text_c(40, int(225 / 8 + 0.5), "BTND / BTNC TO CONTINUE", (23, 71, 94), center=True)
    p.end(at)
    ui.table("T_S3_ROUTE", [("S%d" % n, "  /  ".join(ROUTES[n])) for n in (1, 2, 3)])

    # "?" above the reporter while the cloak hides the player
    p = ui.program("S3_QMARK")
    p.org("F_S3_Q_COL", "F_S3_Q_ROW")
    p.text_c(0, 0, "?", (255, 240, 206), bg=(62, 44, 70))
    p.org()
