"""
uilib.py - the UI "painter" assembler used by ui_compiler.py.

The FPGA draws all text, panels, boxes and labels with an 80x45 text-cell layer (8x8 logical
cells = 640x360, scaled 2x to 1280x720@60 VGA). A tiny command processor (rtl/video/ui_painter.v)
repaints that layer during every vertical blank by running small programs stored in ROM. This file
turns readable Python layout descriptions - written in the SAME 960x540 coordinates the Pygame code
uses - into those ROM words, so positions can be copied straight from the Pygame draw calls.

Instruction words (32 bit):
  word0[31:28] op
  OP_END    0  ----
  OP_RECT   1  col[27:21] row[20:15] border_fg[14:10] border_en[9] dither[8] bg[4:0]   +word1: w[6:0] h[13:8]
  OP_TEXT   2  col row fg[14:10] big[9] center[8] flow[7] lstep-1[6:5] bg[4:0]        +word1: str_addr[15:0]
  OP_FIELD  3  (same word0)                                                           +word1: field[7:0] maxlen[15:8]
  OP_SKIPZ  4  cond[27:20] n[11:0]   skip n words when cond == 0
  OP_SKIPNZ 5  cond[27:20] n[11:0]   skip n words when cond == 1
  OP_ORG    6  fx[27:20] fy[19:12]   origin (signed cells) = field values, 0xFF = 0
  OP_STRSEL 7  (TEXT word0)                                                           +word1: table[15:0] sel_field[23:16]
  OP_CHAR   8  (TEXT word0)                                                           +word1: glyph[7:0] count[14:8]
  OP_SETCUR 9  row[20:15]            "flow" text continues from this row
bg = 31 keeps the background already in the cell. Text cell = {glyph[6:0], fg[4:0], bg[4:0], big, qx, qy}.
"""
import math

OP = dict(END=0, RECT=1, TEXT=2, FIELD=3, SKIPZ=4, SKIPNZ=5, ORG=6, STRSEL=7, CHAR=8, SETCUR=9)
KEEP = 31
VIEW_ROW0 = 0          # native 16:9: the 640x360 game view fills the full 80x45 (1280x720/2) screen
SCALE = 2.0 / 3.0      # Pygame UI (960x540) -> FPGA view (640x360)

# Pygame font heights (pixels in the 960x540 UI) - used to centre our 8 px glyph on the line
FONT_H = {"tiny": 11, "s": 14, "m": 18, "l": 26, "mono": 20, "mono_l": 29}
BIG_FONTS = ("l",)


class Palette:
    """Collects every colour used by the layouts; index 0 = black/transparent, 31 = KEEP."""

    def __init__(self):
        self.cols = [(0, 0, 0)]

    def __call__(self, rgb):
        if rgb is None:
            return KEEP
        c = tuple(int(round(v / 17.0)) for v in rgb)
        if c in self.cols:
            return self.cols.index(c)
        if len(self.cols) < 31:
            self.cols.append(c)
            return len(self.cols) - 1
        # palette full: nearest existing colour
        return min(range(1, len(self.cols)), key=lambda i: sum((a - b) ** 2 for a, b in zip(self.cols[i], c)))


class Strings:
    def __init__(self):
        self.data = bytearray([0])   # address 0 = empty string
        self.index = {"": 0}

    def add(self, s):
        if s in self.index:
            return self.index[s]
        a = len(self.data)
        for ch in s:
            o = ord(ch)
            if o == 10:
                self.data.append(10)
            elif 32 <= o < 127:
                self.data.append(o)
            else:
                self.data.append(ord("?"))
        self.data.append(0)
        self.index[s] = a
        return a


def wrap(text, width_chars):
    """pygame-style greedy word wrap on character count."""
    lines = []
    for para in text.split("\n"):
        cur = ""
        for word in para.split(" "):
            t = (cur + " " + word).strip()
            if len(t) <= width_chars or not cur:
                cur = t
            else:
                lines.append(cur)
                cur = word
        lines.append(cur)
    return lines


class Registry:
    """Global names for fields (F_), conditions (C_), programs (P_) and string tables (T_)."""

    def __init__(self):
        self.fields, self.conds, self.progs, self.tables = {}, {}, {}, {}

    def f(self, name):
        if name not in self.fields:
            self.fields[name] = len(self.fields) + 1
            assert self.fields[name] < 255
        return self.fields[name]

    def c(self, name):
        if name not in self.conds:
            self.conds[name] = len(self.conds) + 1
            assert self.conds[name] < 255
        return self.conds[name]


class Program:
    def __init__(self, ui, name):
        self.ui, self.name = ui, name
        self.words = []          # (value, fixup) - fixups resolved at link time
        self.ox = 0              # x offset (Pygame subsurface origin, e.g. 160 for close-ups)

    # ---------------- coordinate helpers (Pygame UI px -> text cells) ----------------
    def col(self, ux):
        return int(math.floor((self.ox + ux) * SCALE / 8.0 + 0.5))

    def row(self, uy, font="m"):
        h = FONT_H.get(font, 18)
        big = font in BIG_FONTS
        y = (uy + h / 2.0) * SCALE - (8 if big else 4)
        return max(0, int(math.floor(y / 8.0 + 0.5)))

    def rowr(self, uy):
        return int(math.floor(uy * SCALE / 8.0 + 0.5)) + VIEW_ROW0

    # ---------------- raw emit ----------------
    def emit(self, w, fix=None):
        self.words.append((w & 0xFFFFFFFF, fix))

    def _w0(self, op, col, row, fg=0, big=0, center=0, flow=0, lstep=1, bg=KEEP):
        assert 0 <= row < 64, (self.name, row)
        col &= 0x7F
        return (OP[op] << 28) | (col << 21) | (row << 15) | (fg << 10) | (big << 9) | (center << 8) | \
               (flow << 7) | (((lstep - 1) & 3) << 5) | (bg & 31)

    # ---------------- drawing ops (cell coordinates) ----------------
    def rect_c(self, col, row, w, h, bg, border=None, dither=None):
        """dither = colour of a 50% checker pattern drawn in the cells (used for translucent stains)."""
        P = self.ui.pal
        bgi = P(bg) if bg is not None else KEEP
        bfg = P(border) if border is not None else (P(dither) if dither else 0)
        self.emit((OP["RECT"] << 28) | ((col & 0x7F) << 21) | (row << 15) | (bfg << 10) |
                  ((1 if border is not None else 0) << 9) | ((1 if dither else 0) << 8) | bgi)
        self.emit((max(1, w) & 0x7F) | ((max(1, h) & 0x3F) << 8))

    def text_c(self, col, row, s, fg, big=False, center=False, bg=None, flow=False, lstep=1):
        a = self.ui.strings.add(s)
        self.emit(self._w0("TEXT", col, row, self.ui.pal(fg), int(big), int(center), int(flow), lstep,
                           self.ui.pal(bg) if bg is not None else KEEP))
        self.emit(a)

    def field_c(self, col, row, field, fg, maxlen=40, big=False, center=False, bg=None):
        fid = self.ui.reg.f(field)
        self.emit(self._w0("FIELD", col, row, self.ui.pal(fg), int(big), int(center), 0, 1,
                           self.ui.pal(bg) if bg is not None else KEEP))
        self.emit(fid | (maxlen << 8))

    def strsel_c(self, col, row, table, field, fg, big=False, center=False, bg=None, flow=False, lstep=1):
        fid = self.ui.reg.f(field)
        self.emit(self._w0("STRSEL", col, row, self.ui.pal(fg), int(big), int(center), int(flow), lstep,
                           self.ui.pal(bg) if bg is not None else KEEP))
        self.emit((fid << 16), ("table", table))

    def char_c(self, col, row, glyph, fg, count=1, big=False, bg=None):
        self.emit(self._w0("CHAR", col, row, self.ui.pal(fg), int(big), 0, 0, 1,
                           self.ui.pal(bg) if bg is not None else KEEP))
        self.emit((glyph & 0xFF) | ((count & 0x7F) << 8))

    def setcur(self, row):
        self.emit((OP["SETCUR"] << 28) | (row << 15))

    def org(self, fx=None, fy=None):
        a = self.ui.reg.f(fx) if fx else 0xFF
        b = self.ui.reg.f(fy) if fy else 0xFF
        self.emit((OP["ORG"] << 28) | (a << 20) | (b << 12))

    # ---------------- structured conditions ----------------
    def if_(self, cond, neg=False):
        cid = self.ui.reg.c(cond)
        self.emit(((OP["SKIPNZ"] if neg else OP["SKIPZ"]) << 28) | (cid << 20), ("skip", None))
        return len(self.words) - 1

    def end(self, at):
        n = len(self.words) - at - 1
        v, _ = self.words[at]
        self.words[at] = (v | n, None)

    # ---------------- Pygame-style helpers (UI coordinates) ----------------
    def rect(self, x, y, w, h, bg, border=None, dither=None):
        c0, c1 = self.col(x), self.col(x + w)
        r0, r1 = self.rowr(y), self.rowr(y + h)
        self.rect_c(c0, r0, c1 - c0, r1 - r0, bg, border, dither)

    def txt(self, text, x, y, font="m", color=(255, 255, 255), bg=None):
        big = font in BIG_FONTS
        self.text_c(self.col(x), self.row(y, font), text, color, big=big, bg=bg)

    def ctxt(self, text, cx, y, font="m", color=(255, 255, 255), bg=None):
        big = font in BIG_FONTS
        self.text_c(self.col(cx), self.row(y, font), text, color, big=big, center=True, bg=bg)

    def wraptxt(self, text, x, y, width, font="m", color=(255, 255, 255), lh=None, max_lines=99, bg=None):
        """blit_wrap: wraps to the pixel width of the Pygame box (8 px per character here)."""
        chars = max(1, int(width * SCALE / (16 if font in BIG_FONTS else 8)))
        lines = wrap(text, chars)[:max_lines]
        lh = lh or FONT_H.get(font, 18) + 4
        step = max(1, int(round(lh * SCALE / 8.0)))
        self.text_c(self.col(x), self.row(y, font), "\n".join(lines), color, big=font in BIG_FONTS,
                    lstep=step, bg=bg)
        return len(lines)

    def fld(self, field, x, y, font="m", color=(255, 255, 255), maxlen=40, center=False, bg=None):
        self.field_c(self.col(x), self.row(y, font), field, color, maxlen, big=font in BIG_FONTS,
                     center=center, bg=bg)

    def sel(self, table, field, x, y, font="m", color=(255, 255, 255), center=False, bg=None, lh=None):
        lh = lh or FONT_H.get(font, 18) + 4
        step = max(1, int(round(lh * SCALE / 8.0)))
        self.strsel_c(self.col(x), self.row(y, font), table, field, color, big=font in BIG_FONTS,
                      center=center, bg=bg, lstep=step)


class UI:
    def __init__(self):
        self.pal = Palette()
        self.strings = Strings()
        self.reg = Registry()
        self.programs = []
        self.tables = {}          # name -> (list of strings, list of entry names)

    def program(self, name):
        p = Program(self, name)
        self.programs.append(p)
        self.reg.progs[name] = len(self.programs)       # id 0 = "nothing"
        return p

    def table(self, name, entries, wrap_chars=None, center=False):
        """entries: list of (NAME, text). Text is pre-wrapped to wrap_chars per line."""
        out = []
        for key, text in entries:
            if wrap_chars:
                text = "\n".join(wrap(text, wrap_chars))
            out.append((key, text))
        self.tables[name] = out
        return name

    def link(self):
        """Program ROM = [program table][string-pointer tables][code]."""
        n_prog = len(self.programs) + 1
        rom = [0] * n_prog
        table_addr = {}
        for name, entries in self.tables.items():
            table_addr[name] = len(rom)
            for key, text in entries:
                rom.append(self.strings.add(text))
        for i, p in enumerate(self.programs):
            rom[i + 1] = len(rom)
            for v, fix in p.words:
                if fix and fix[0] == "table":
                    v |= table_addr[fix[1]]
                rom.append(v)
            rom.append(0)                                  # END
        return rom, table_addr
