#!/usr/bin/env python3
"""
asset_compiler.py - converts the REAL game pictures (assets/, onlystage_3/) into
Block-RAM ROM images (.mem) for the Nexys A7-100T and checks that they FIT.

    python3 fpga/tools/asset_compiler.py            (run from the repository root)

Outputs
    fpga/mem/rom_p4.mem      4-bit sprite pixels (palette index, 0 = transparent)
    fpga/mem/rom_vqi.mem     9-bit VQ block indices (backgrounds, story slides, buildings)
    fpga/mem/rom_cb.mem      8-bit VQ codebook pixels (16 per code word)
    fpga/mem/rom_pal.mem     12-bit RGB444 palette entries
    fpga/mem/rom_map.mem     8-bit Stage 3 tile maps (3 levels x 250 x 11)
    fpga/rtl/gen/asset_dir.vh      asset directory ROM (Verilog function)
    fpga/rtl/gen/asset_ids.vh      asset id / size constants used by the scene builders
    fpga/rtl/gen/tile_dir.vh       Stage 3 tile directory ROM (Verilog function)
    fpga/docs/bram_report.md       exact RAMB36 count of every ROM + budget check
    fpga/build/preview/*.png       pictures decoded back from the ROM data (what the FPGA shows)

Encodings (chosen per asset, see docs/ASSETS.md)
    P4  : 4 bits / pixel + a private 16-entry palette. Used for the 32x32-grid pixel art
          (player, NPCs, cards, animals, icons, small tiles). Lossless for <=15-colour art.
    VQ  : 4x4 block vector quantisation. Every 4x4 block is replaced by the nearest of 512
          "code words" (9-bit index). Code word pixels are 8-bit indices into a 256-colour
          group palette. 0.56 bit / pixel. Used for the large photo-like pictures.
The script stops with an error if the total exceeds BUDGET_RAMB36.
"""
import hashlib, json, math, os, sys
from collections import OrderedDict

import numpy as np
from PIL import Image
from sklearn.cluster import MiniBatchKMeans

# --------------------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------------------
ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
FPGA = r"c:\Users\LENOVO\Desktop\fpga"
A1 = os.path.join(ROOT, "assets")
A3 = os.path.join(ROOT, "onlystage_3", "assets")
OUT_MEM = os.path.join(FPGA, "mem")
OUT_GEN = os.path.join(FPGA, "rtl", "gen")
OUT_DOC = os.path.join(FPGA, "docs")
OUT_PRV = os.path.join(FPGA, "build", "preview")

BUDGET_RAMB36 = 100          # hard limit for ALL asset ROMs (device has 135); rest is left for
                             # text RAM, line buffers, font, UI program and Stage 2 walk mask.
DEVICE_RAMB36 = 135          # XC7A100T (Nexys A7-100T)
VQ_K = 512                   # code words per VQ group (9-bit index)
STORY_W, STORY_H = 320, 180  # story slides: 320x180 stored, shown 2x (640x360)
SEED = 1

TRANSPARENT = None


def rgb444(c):
    return tuple(int(round(v / 17.0)) for v in c[:3])


def hex12(c):
    r, g, b = c
    return "%X%X%X" % (r, g, b)


def load_rgba(path):
    return Image.open(path).convert("RGBA")


def grid_native(img, grid):
    """Sample the centre of each grid x grid cell (pixel-art source -> native resolution)."""
    w, h = img.size
    nw, nh = w // grid, h // grid
    a = np.asarray(img)
    ys = np.arange(nh) * grid + grid // 2
    xs = np.arange(nw) * grid + grid // 2
    return Image.fromarray(a[ys][:, xs])


def alpha_bbox(img, thr=128):
    a = np.asarray(img)[..., 3]
    ys, xs = np.nonzero(a >= thr)
    if len(xs) == 0:
        return (0, 0, 1, 1)
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


# --------------------------------------------------------------------------------------
# asset records
# --------------------------------------------------------------------------------------
class Asset:
    def __init__(self, name, kind, img, note="", full=None, crop=(0, 0)):
        self.name, self.kind, self.img, self.note = name, kind, img, note
        self.w, self.h = img.size
        self.full = full or img.size           # size of the uncropped frame (native px)
        self.ox, self.oy = crop                # where the crop starts inside the full frame
        self.base = 0                          # ROM base address (P4: pixel, VQ: block index)
        self.pal = 0                           # palette base (P4) or code-book base (VQ, in code words)
        self.group = None
        self.idx = None                        # VQ indices / P4 pixels after encoding
        self.aid = None


ASSETS = OrderedDict()
P4_LIST, VQ_GROUPS = [], OrderedDict()


def add_p4(name, img, note="", full=None, crop=(0, 0)):
    a = Asset(name, "P4", img, note, full, crop)
    ASSETS[name] = a
    P4_LIST.append(a)
    return a


def add_vq(name, group, img, note=""):
    a = Asset(name, "VQ", img, note)
    a.group = group
    ASSETS[name] = a
    VQ_GROUPS.setdefault(group, []).append(a)
    return a


def sprite640(name, path, note="", grid=20, keep_full=False):
    """32x32 pixel-art sprite stored at native resolution, cropped to its opaque box."""
    img = load_rgba(path)
    nat = grid_native(img, grid)
    if keep_full:
        return add_p4(name, nat, note, nat.size, (0, 0))
    x0, y0, x1, y1 = alpha_bbox(nat)
    return add_p4(name, nat.crop((x0, y0, x1, y1)), note, nat.size, (x0, y0))


# --------------------------------------------------------------------------------------
# 1. player sprites (4 forms x 4 directions x 3 poses) - the exact files that exist
# --------------------------------------------------------------------------------------
DIRS = ("front", "back", "left", "right")
POSES = ("stand", "stepl", "stepr")


def find(*cands):
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


PLAYER_FILE = {}
for form in range(4):
    for d in DIRS:
        for p in POSES:
            fn = "player_form%d_%s_%s.png" % (form, d, p)
            path = find(os.path.join(A1, fn), os.path.join(A3, fn))
            if path:
                PLAYER_FILE[(form, d, p)] = path
for form in (2, 3):                                   # Stage 3 'right2' skins (cloak / phase)
    for p in POSES:
        fn = "player_form%d_right2_%s.png" % (form, p)
        if os.path.isfile(os.path.join(A3, fn)):
            PLAYER_FILE[(form, "right2", p)] = os.path.join(A3, fn)

for key in sorted(PLAYER_FILE, key=lambda k: (k[0], (DIRS + ("right2",)).index(k[1]), POSES.index(k[2]))):
    form, d, p = key
    sprite640("pl_f%d_%s_%s" % (form, d, p), PLAYER_FILE[key], "player")

# --------------------------------------------------------------------------------------
# 2. NPCs, Stage 3 actors, items
# --------------------------------------------------------------------------------------
def strip_white(img):
    """stage1_demo.load_guide_sprite: flood-fill the opaque white border to transparent."""
    a = np.array(img)
    h, w = a.shape[:2]
    white = (a[..., 0] >= 245) & (a[..., 1] >= 245) & (a[..., 2] >= 245) & (a[..., 3] == 255)
    seen = np.zeros_like(white)
    stack = [(y, x) for y, x in ((0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)) if white[y, x]]
    for y, x in stack:
        seen[y, x] = True
    while stack:
        y, x = stack.pop()
        a[y, x] = (255, 255, 255, 0)
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and white[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                stack.append((ny, nx))
    return Image.fromarray(a)


ta = strip_white(load_rgba(os.path.join(A1, "intro_char.png")))
ta_nat = grid_native(ta, 20)
x0, y0, x1, y1 = alpha_bbox(ta_nat)
add_p4("npc_ta", ta_nat.crop((x0, y0, x1, y1)), "Stage 1 TA guide (intro_char.png)", ta_nat.size, (x0, y0))
sprite640("npc_boss", os.path.join(A1, "Boss.png"), "Stage 2 Boss (Boss.png)", keep_full=True)
sprite640("rep_stand", os.path.join(A3, "reporter_stand.png"), "Stage 3 reporter", grid=32, keep_full=True)
sprite640("rep_step", os.path.join(A3, "reporter_step.png"), "Stage 3 reporter", grid=32, keep_full=True)

ANIMAL_FILES = ["snail_1.png", "snail1_1.png", "snail.png", "snail1.png", "squirrel_1.png", "squirrel.png",
                "ant_1.png", "snail_2.png", "snail_22.png", "snail1_2.png", "snail1_22.png", "squirrel_2.png",
                "ant_2.png", "goose_2.png", "goose.png", "snail_3.png", "snail1_3.png", "squirrel_3.png",
                "ant_3.png", "goose_3.png"]
for fn in ANIMAL_FILES:
    # render.animal_sprite: crop alpha bbox, height round(ANIMAL_HEIGHT*32)=27 px, NEAREST.
    img = load_rgba(os.path.join(A3, fn))
    bb = img.getchannel("A").getbbox()
    img = img.crop(bb)
    h = round(1.5 / 1.75 * 32)
    img = img.resize((max(1, round(img.width * h / img.height)), h), Image.NEAREST)
    add_p4("an_" + fn[:-4], img, "Stage 3 animal (display size)")

tea = load_rgba(os.path.join(A3, "milk_tea_2.png"))
tea = tea.crop(tea.getchannel("A").getbbox())
th = round(1.7 * 32)
add_p4("s3_tea", tea.resize((max(1, round(th * tea.width / tea.height)), th), Image.NEAREST), "milk tea")
add_p4("s3_block", load_rgba(os.path.join(A3, "puzzle_2.png")).resize((32, 32), Image.NEAREST), "? block")
for fn in ("skill_cloak", "skill_cloak_used", "skill_phase", "skill_phase_used"):
    add_p4("s3_" + fn, load_rgba(os.path.join(A3, fn + ".png")).resize((35, 35), Image.NEAREST), "skill icon")

sys.path.insert(0, ROOT)
try:
    import onlystage_3.hud as _hud                                   # the game's own procedural clock icon
    add_p4("s3_clock", _hud.frost_clock().convert("RGBA"), "frost clock (hud.frost_clock)")
except Exception as e:                                               # pragma: no cover
    print("warning: could not draw the HUD clock:", e)

# --------------------------------------------------------------------------------------
# 3. cards (career round 1, round 2-3 backs, item fronts) - deduplicated by content
# --------------------------------------------------------------------------------------
CARD_NAMES = []
for cat in ("air", "earth", "water"):
    for st in ("back", "r1", "card1", "card2", "card3", "freeze", "heart_loss", "hint_hard", "hint_smart",
               "shard", "slow", "undo"):
        CARD_NAMES.append("%s_%s" % (cat, st))
CARD_ALIAS = {}
_seen = {}
for n in CARD_NAMES:
    path = os.path.join(A1, n + ".png")
    img = load_rgba(path)
    grid = 20 if img.width == 640 else img.width / 32.0
    nat = grid_native(img, int(round(grid))) if img.width == 640 else img.resize((32, 32), Image.NEAREST)
    h = hashlib.md5(np.asarray(nat).tobytes()).hexdigest()
    if h in _seen:
        CARD_ALIAS[n] = _seen[h]
        continue
    _seen[h] = n
    CARD_ALIAS[n] = n
    x0, y0, x1, y1 = alpha_bbox(nat)
    add_p4("card_" + n, nat.crop((x0, y0, x1, y1)), "card", nat.size, (x0, y0))

LOGOS = ["canva", "pinterest", "explorer", "appstore", "x", "facebook"]
for n in LOGOS:
    img = load_rgba(os.path.join(A1, "app_logo_%s.png" % n)).resize((16, 16), Image.LANCZOS)
    add_p4("logo_" + n, img, "projector app logo (22x22 UI px)")

# --------------------------------------------------------------------------------------
# 4. Stage 3 tiles - rendered with the game's own Level/Tileset code (exact)
# --------------------------------------------------------------------------------------
import onlystage_3.settings as S3
from onlystage_3.level import Level

TILES = []              # unique tile images (RGBA 32x32)
TILE_KEY = {}
MAPS = {}
LEVEL_INFO = {}
EMPTY = 0


def tile_id(img):
    h = hashlib.md5(img.tobytes()).hexdigest()
    if h not in TILE_KEY:
        TILE_KEY[h] = len(TILES) + 1        # 0 = empty cell
        TILES.append(img.convert("RGBA"))
    return TILE_KEY[h]


for n, f in S3.MAPS.items():
    lv = Level(S3.ASSETS / f)
    grid = np.zeros((lv.height, lv.width), dtype=np.int32)
    roles = np.zeros((lv.height, lv.width), dtype=np.int32)      # 0 empty 1 solid 2 water 3 decor
    for b, role, ts, num, flags, alpha in lv.cells:
        img = ts.image(num, flags, alpha, 0.0)
        r = lv.height - 1 - int(b.y)
        c = int(b.x)
        if grid[r, c]:
            raise SystemExit("two visible tiles in one cell (level %d col %d) - compiler needs a 2nd layer" % (n, c))
        grid[r, c] = tile_id(img)
        roles[r, c] = {"solid": 1, "water": 2}.get(role, 3)
    MAPS[n] = grid
    LEVEL_INFO[n] = dict(w=lv.width, h=lv.height, solids=len(lv.solids), water=len(lv.water))

# lift planks (render.platform_art + upper_plank) are drawn as sprites
try:
    from onlystage_3.render import upper_plank
    for sink in (False, True):
        lv = Level(S3.ASSETS / ("maidown_3.tmj" if sink else "mai_3.tmj"))
        canvas = Image.new("RGBA", (64, 32))
        for cell, _, ts, num, flags, alpha in lv.cells:
            t = upper_plank(ts.image(num, flags, alpha, 0.0), flip=False)
            canvas.paste(t, (int(cell.x) * 32, 0), t)
        bb = canvas.getchannel("A").getbbox() or (0, 0, 64, 1)
        add_p4("s3_lift_%s" % ("sink" if sink else "move"), canvas.crop(bb), "lift plank", (64, 32), bb[:2])
except Exception as e:
    print("warning: lift art:", e)

if len(TILES) > 255:
    raise SystemExit("more than 255 unique tiles")

TILE_KIND = []          # per tile: ("P4"|"VQ", asset)
for i, img in enumerate(TILES):
    a = np.asarray(img)
    m = a[..., 3] >= 128
    cols = {rgb444(c) for c in a[m]}
    if len(cols) <= 15:
        t = add_p4("tile_%03d" % (i + 1), img, "Stage 3 tile")
        TILE_KIND.append(("P4", t))
    else:
        t = add_vq("tile_%03d" % (i + 1), "TILES", img, "Stage 3 tile")
        TILE_KIND.append(("VQ", t))

# --------------------------------------------------------------------------------------
# 5. big pictures (VQ)
# --------------------------------------------------------------------------------------
def fit_canvas(path, w, h, bg=(12, 14, 20)):
    """pygame 'fit' used by open.py / cutscenes: keep aspect, centre on a dark canvas."""
    im = Image.open(path).convert("RGB")
    k = min(w / im.width, h / im.height)
    sm = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.BOX)
    c = Image.new("RGB", (w, h), bg)
    c.paste(sm, ((w - sm.width) // 2, (h - sm.height) // 2))
    return c.convert("RGBA")


# Stage 1 room: world 2000x1116 drawn at ZOOM 0.96 on a 960x540 UI -> 1280x714 screen px.
room = Image.open(os.path.join(A1, "finalexam.jpg")).convert("RGB").resize((640, 357), Image.BOX)
room_c = Image.new("RGB", (640, 360))
room_c.paste(room, (0, 0))
room_c.paste(room.crop((0, 356, 640, 357)).resize((640, 3)), (0, 357))
add_vq("bg_room", "ROOM", room_c.convert("RGBA"), "Stage 1 room, shown 2x (1280x720 world view)")
add_vq("bg_office", "OFFICE", Image.open(os.path.join(A1, "bg.jpg")).convert("RGB").resize((640, 360), Image.BOX).convert("RGBA"),
       "Stage 2 office 640x360 (1x)")

STORY = ["title.png", "1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg", "cutscene1_2.png",
         "cut23_1.png", "cut23_2.png", "cut23_3.png"]
for fn in STORY:
    bg = (0, 0, 0) if fn[0].isdigit() or fn.startswith("title") else (12, 14, 20)
    add_vq("st_" + fn.split(".")[0], "STORY", fit_canvas(os.path.join(A1, fn), STORY_W, STORY_H, bg), "story slide, shown 2x")
def find_end_img(stem):
    for ext in (".png", ".png.png", ".jpg"):
        p = os.path.join(A1, stem + ext)
        if os.path.isfile(p):
            return p
    raise SystemExit("missing ending image: %s (.png / .png.png)" % stem)


def pad4(im):
    im = im.convert("RGBA")
    w, h = (im.width + 3) // 4 * 4, (im.height + 3) // 4 * 4
    if (w, h) == im.size:
        return im
    c = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    c.paste(im, (0, 0))
    return c


bg_im = load_rgba(find_end_img("ending_bg")).resize((640, 360), Image.BOX)
add_vq("st_end_bg", "END_BG", bg_im, "ending background 640x360")
END_CHARS, END_TEXTS = [], []
for i in range(1, 10):
    ch_raw = load_rgba(find_end_img("ending_char%d" % i))
    ch_pad = pad4(ch_raw)
    END_CHARS.append((ch_pad, 22 + (240 - ch_raw.width) // 2, 56 + (240 - ch_raw.height) // 2))
    add_vq("st_end_char%d" % i, "END_CHAR", ch_pad, "ending character %d" % i)
    tx_raw = load_rgba(find_end_img("ending_text%d" % i))
    tx_pad = pad4(tx_raw)
    END_TEXTS.append((tx_pad, min(272, 622 - tx_raw.width), 18 + max(0, (320 - tx_raw.height) // 2)))
    add_vq("st_end_text%d" % i, "END_TXT%d" % ((i - 1) // 3), tx_pad, "ending text %d" % i)
# Stage 3 parallax: sprite(background,(frame.width+2*S, frame.height)) = 704x352, stored half size.
for st, fn in S3.BACKGROUND.items():
    img = Image.open(S3.ASSETS / fn).convert("RGB").resize((704, 352), Image.NEAREST).resize((352, 176), Image.BOX)
    add_vq("s3_sky%d" % st, "SKY", img.convert("RGBA"), "Stage 3 parallax background (shown 2x)")

# --------------------------------------------------------------------------------------
# encoders
# --------------------------------------------------------------------------------------
def encode_p4(a):
    arr = np.asarray(a.img.convert("RGBA"))
    m = arr[..., 3] >= 128
    px = arr[..., :3][m]
    q = np.array([rgb444(c) for c in px], dtype=np.int32).reshape(-1, 3) if len(px) else np.zeros((0, 3), int)
    cols = sorted({tuple(c) for c in q})
    if len(cols) > 15:
        km = MiniBatchKMeans(15, random_state=SEED, n_init=3, batch_size=1024).fit(q.astype(float))
        cols = sorted({tuple(int(round(v)) for v in c) for c in np.clip(km.cluster_centers_, 0, 15)})
    pal = np.array(cols, dtype=np.int32).reshape(-1, 3)
    out = np.zeros(m.shape, dtype=np.int32)
    if len(pal):
        full = np.array([rgb444(c) for c in arr[..., :3].reshape(-1, 3)]).reshape(m.shape + (3,))
        d = ((full[..., None, :] - pal[None, None, :, :]) ** 2).sum(-1)
        out = d.argmin(-1) + 1
    out[~m] = 0
    a.idx = out
    a.palette = [tuple(map(int, c)) for c in pal] + [(0, 0, 0)] * (15 - len(pal))


def blocks(arr, b=4):
    h, w = arr.shape[:2]
    return arr.reshape(h // b, b, w // b, b, -1).transpose(0, 2, 1, 3, 4).reshape((h // b) * (w // b), b * b, -1)


def encode_vq_group(name, assets):
    """palette (255 colours + transparent) -> 4x4 block code book (VQ_K words) -> indices."""
    for a in assets:
        if a.w % 4 or a.h % 4:
            raise SystemExit("%s: VQ size must be a multiple of 4 (%dx%d)" % (a.name, a.w, a.h))
    arrs = [np.asarray(a.img.convert("RGBA")).astype(np.float32) for a in assets]
    has_alpha = any((x[..., 3] < 128).any() for x in arrs)
    opaque = np.concatenate([x[..., :3][x[..., 3] >= 128] for x in arrs])
    ncol = 255
    rng = np.random.default_rng(SEED)
    sample = opaque[rng.choice(len(opaque), min(len(opaque), 200000), replace=False)]
    km = MiniBatchKMeans(ncol, random_state=SEED, n_init=1, batch_size=8192, max_iter=80).fit(sample)
    pal = np.unique(np.clip(np.round(km.cluster_centers_ / 17.0), 0, 15).astype(int), axis=0)
    pal_rgb = pal * 17.0                                         # index i+1 = pal[i]; index 0 = transparent
    # block vectors in RGB (+ alpha channel weighted strongly)
    vecs = []
    for x in arrs:
        al = (x[..., 3:4] >= 128).astype(np.float32) * 400.0
        vecs.append(blocks(np.concatenate([x[..., :3], al], -1)).reshape(-1, 16 * 4))
    V = np.concatenate(vecs)
    K = min(VQ_K, len(V))
    km2 = MiniBatchKMeans(K, random_state=SEED, n_init=1, batch_size=8192, max_iter=100).fit(V)
    C = km2.cluster_centers_.reshape(K, 16, 4)
    cw = np.zeros((K, 16), dtype=np.int32)
    for k in range(K):
        rgb = C[k, :, :3]
        d = ((rgb[:, None, :] - pal_rgb[None]) ** 2).sum(-1)
        cw[k] = d.argmin(-1) + 1
        if has_alpha:
            cw[k][C[k, :, 3] < 200.0] = 0
    # re-assign every block to the code word that decodes closest (exact decoder space)
    dec = np.concatenate([np.zeros((1, 3)), pal_rgb])[cw]                # K x 16 x 3
    dec_a = (cw > 0).astype(np.float32) * 400.0
    D = np.concatenate([dec, dec_a[..., None]], -1).reshape(K, 64)
    for a, v in zip(assets, vecs):
        best = np.empty(len(v), dtype=np.int32)
        for s in range(0, len(v), 4096):
            chunk = v[s:s + 4096]
            d = (chunk ** 2).sum(1)[:, None] - 2 * chunk @ D.T + (D ** 2).sum(1)[None]
            best[s:s + 4096] = d.argmin(1)
        a.idx = best
    VQ_BOOK[name] = dict(cw=cw, pal=[tuple(map(int, c)) for c in pal], K=K, alpha=has_alpha)


VQ_BOOK = OrderedDict()
print("encoding %d P4 assets ..." % len(P4_LIST))
for a in P4_LIST:
    encode_p4(a)
for g, lst in VQ_GROUPS.items():
    print("encoding VQ group %-7s : %d pictures" % (g, len(lst)))
    encode_vq_group(g, lst)

# --------------------------------------------------------------------------------------
# ROM layout
# --------------------------------------------------------------------------------------
rom_p4, rom_vqi, rom_cb, rom_pal = [], [], [], []
for a in P4_LIST:                       # P4 palettes first (16 entries each)
    a.pal = len(rom_pal)
    rom_pal += [(0, 0, 0)] + a.palette
    a.base = len(rom_p4)
    rom_p4 += [int(v) for v in a.idx.reshape(-1)]
for g, book in VQ_BOOK.items():
    book["pal_base"] = len(rom_pal)
    rom_pal += [(0, 0, 0)] + book["pal"]
    while len(rom_pal) % 256:           # VQ palettes are 256 entries (8-bit pixel index)
        rom_pal.append((0, 0, 0))
    book["cb_base"] = len(rom_cb) // 16
    rom_cb += [int(v) for v in book["cw"].reshape(-1)]
    for a in VQ_GROUPS[g]:
        a.base = len(rom_vqi)
        a.pal = book["cb_base"]
        a.pal_base = book["pal_base"]
        rom_vqi += [int(v) for v in a.idx]

rom_map = []
LEVEL_BASE = {}
for n in sorted(MAPS):
    LEVEL_BASE[n] = len(rom_map)
    rom_map += [int(v) for v in MAPS[n].reshape(-1)]

aid = 0
for a in ASSETS.values():
    if a.name.startswith("tile_"):
        continue                        # tiles are reached through tile_dir, not through an asset id
    a.aid = aid
    aid += 1
if aid > 256:
    raise SystemExit("too many assets for an 8-bit id")


# --------------------------------------------------------------------------------------
# Block RAM cost model (7-series RAMB36E1 aspect ratios, data + parity bits)
# --------------------------------------------------------------------------------------
CONFIGS = [(32768, 1), (16384, 2), (8192, 4), (4096, 9), (2048, 18), (1024, 36)]


def ramb36(depth, width):
    if depth == 0:
        return 0, "-"
    best = None
    for d, w in CONFIGS:
        n = math.ceil(depth / d) * math.ceil(width / w)
        if best is None or n < best[0]:
            best = (n, "%dKx%d" % (d // 1024, w))
    # a ROM that needs <= half a RAMB36 can use one RAMB18
    if depth * width <= 18432 and best[0] == 1:
        return 0.5, "RAMB18"
    return best


ROMS = [("rom_p4", rom_p4, 4, "sprite pixels (P4)"),
        ("rom_vqi", rom_vqi, 9, "VQ block indices"),
        ("rom_cb", rom_cb, 8, "VQ code books (16 px per word)"),
        ("rom_pal", rom_pal, 12, "palettes RGB444"),
        ("rom_map", rom_map, 8, "Stage 3 tile maps")]

# fixed system memories (allocated by the RTL, reported here so the total is complete)
SYSTEM = [("text_ram", 4800, 20, "80x60 text cells (glyph, fg, bg, size)"),
          ("font_rom", 1024, 8, "128 glyphs x 8 rows"),
          ("ui_prog", 4096, 32, "UI program ROM (generated by ui_compiler.py)"),
          ("ui_str", 32768, 8, "UI string ROM"),
          ("line_buf", 2048, 12, "2 x 1024 x 12 line buffers"),
          ("walk_mask", 480 * 272, 1, "Stage 2 walkable floor (2 px grid)")]

# --------------------------------------------------------------------------------------
# write files
# --------------------------------------------------------------------------------------
for d in (OUT_MEM, OUT_GEN, OUT_DOC, OUT_PRV):
    os.makedirs(d, exist_ok=True)


def write_mem(name, data, width):
    digits = (width + 3) // 4
    with open(os.path.join(OUT_MEM, name + ".mem"), "w") as f:
        f.write("// %s : %d x %d bit (generated by asset_compiler.py)\n" % (name, len(data), width))
        for v in data:
            if isinstance(v, tuple):
                v = (v[0] << 8) | (v[1] << 4) | v[2]
            f.write("%0*X\n" % (digits, v))


for name, data, width, _ in ROMS:
    write_mem(name, data, width)


def vname(s):
    return "".join(c if c.isalnum() else "_" for c in s).upper()


# asset directory: {kind, w, h, base, pal/cb, pal_base}
with open(os.path.join(OUT_GEN, "asset_dir.vh"), "w") as f:
    f.write("// generated by fpga/tools/asset_compiler.py - do not edit\n")
    f.write("// asset_dir(id) = {kind, w[9:0], h[9:0], base[17:0], cbase[12:0], pbase[12:0]}  (65 bits)\n")
    f.write("//   kind 0 = P4 (base = pixel address, pbase = 16-entry palette)\n")
    f.write("//   kind 1 = VQ (base = block index address, cbase = code-word base, pbase = 256-entry palette)\n")
    f.write("function [64:0] asset_dir;\n  input [7:0] id;\n  begin\n    case (id)\n")
    for a in ASSETS.values():
        if a.aid is None:
            continue
        kind = 0 if a.kind == "P4" else 1
        pbase = a.pal if a.kind == "P4" else a.pal_base
        cbase = 0 if a.kind == "P4" else a.pal
        f.write("      8'd%d: asset_dir = {1'b%d, 10'd%d, 10'd%d, 18'd%d, 13'd%d, 13'd%d}; // %s\n"
                % (a.aid, kind, a.w, a.h, a.base, cbase, pbase, a.name))
    f.write("      default: asset_dir = 65'd0;\n    endcase\n  end\nendfunction\n")

with open(os.path.join(OUT_GEN, "asset_ids.vh"), "w") as f:
    f.write("// generated by fpga/tools/asset_compiler.py - do not edit\n")
    f.write("// A_<name> = asset id,  AW_/AH_ = stored size,  AFW_/AFH_ = uncropped frame size,\n")
    f.write("// AOX_/AOY_ = position of the stored crop inside the frame (all in stored pixels)\n")
    for a in ASSETS.values():
        if a.aid is None:
            continue
        n = vname(a.name)
        f.write("localparam [7:0] A_%s = 8'd%d;\n" % (n, a.aid))
        f.write("localparam AW_%s = %d, AH_%s = %d, AFW_%s = %d, AFH_%s = %d, AOX_%s = %d, AOY_%s = %d;\n"
                % (n, a.w, n, a.h, n, a.full[0], n, a.full[1], n, a.ox, n, a.oy))
    f.write("localparam N_ASSETS = %d;\n" % aid)
    # card aliases: names whose picture is identical to another card
    for n, tgt in CARD_ALIAS.items():
        f.write("localparam [7:0] C_%s = A_%s;\n" % (vname(n), vname("card_" + tgt)))
    for i, n in enumerate(LOGOS):
        f.write("localparam [7:0] LOGO_%d = A_LOGO_%s;\n" % (i, vname(n)))
    for n in sorted(LEVEL_BASE):
        f.write("localparam [13:0] MAP_BASE_%d = 14'd%d;\n" % (n, LEVEL_BASE[n]))
    f.write("localparam N_TILES = %d;\n" % len(TILES))

def aw(n):
    return max(1, (max(1, n) - 1).bit_length())


with open(os.path.join(OUT_GEN, "rom_sizes.vh"), "w") as f:
    f.write("// generated by fpga/tools/asset_compiler.py - ROM depths and address widths\n")
    for name, data, width, _ in ROMS:
        n = name[4:].upper()
        f.write("localparam %s_DEPTH = %d;\nlocalparam %s_AW = %d;\n" % (n, len(data), n, aw(len(data))))

with open(os.path.join(OUT_GEN, "vmap.vh"), "w") as f:
    f.write("// generated: Stage 3 draws a 640x352 frame that Pillow stretches to 640x360 (NEAREST).\n")
    f.write("// vmap(vy) = source row for view row vy = floor((vy + 0.5) * 352 / 360)\n")
    f.write("function [8:0] vmap;\n  input [8:0] v;\n  begin\n    case (v)\n")
    for vy in range(360):
        f.write("      9'd%d: vmap = 9'd%d;\n" % (vy, int((vy + 0.5) * 352 / 360)))
    f.write("      default: vmap = 9'd351;\n    endcase\n  end\nendfunction\n")

# ---- sprite placement tables: where Pygame puts each picture, per drawing context ----
# packed {dx_off[10:0] signed, dy_off[9:0] signed, w[9:0], h[8:0], step[9:0]} = 50 bits
# dx_off/dy_off are relative to the anchor point (feet / slot centre) in VIEW pixels (640x360).
def place(a, k, mode):
    fw, fh = a.full
    w, h = max(1, round(a.w * k)), max(1, round(a.h * k))
    if mode == "feet_full":          # whole frame scaled, bottom-centre at the anchor
        dx, dy = -fw * k / 2 + a.ox * k, -fh * k + a.oy * k
    elif mode == "feet_crop":        # cropped picture, bottom-centre at the anchor
        dx, dy = -w / 2.0, -h
    else:                            # "center": frame centred on the anchor
        dx, dy = -fw * k / 2 + a.ox * k, -fh * k / 2 + a.oy * k
    step = min(1023, max(1, round(256.0 / k)))
    return int(math.floor(dx + 0.5)), int(math.floor(dy + 0.5)), w, h, step


def place_func(f, name, items, comment):
    f.write("// %s\nfunction [49:0] %s;\n  input [7:0] id;\n  begin\n    case (id)\n" % (comment, name))
    for a, k, mode in items:
        dx, dy, w, h, st = place(a, k, mode)
        f.write("      8'd%d: %s = {11'sd%d, 10'sd%d, 10'd%d, 9'd%d, 10'd%d}; // %s\n" % (
            a.aid, name, dx, dy, w, h, st, a.name) if dx >= 0 and dy >= 0 else
            "      8'd%d: %s = {-11'sd%d, -10'sd%d, 10'd%d, 9'd%d, 10'd%d}; // %s\n" % (
            a.aid, name, -dx, -dy, w, h, st, a.name) if dx < 0 and dy < 0 else
            "      8'd%d: %s = {%s11'sd%d, %s10'sd%d, 10'd%d, 9'd%d, 10'd%d}; // %s\n" % (
            a.aid, name, "-" if dx < 0 else "", abs(dx), "-" if dy < 0 else "", abs(dy), w, h, st, a.name))
    f.write("      default: %s = 50'd0;\n    endcase\n  end\nendfunction\n" % name)


players = [a for a in ASSETS.values() if a.name.startswith("pl_")]
cards = [a for a in ASSETS.values() if a.name.startswith("card_")]
ta = ASSETS["npc_ta"]
boss = ASSETS["npc_boss"]
with open(os.path.join(OUT_GEN, "sprite_place.vh"), "w") as f:
    f.write("// generated by fpga/tools/asset_compiler.py - sprite placement per drawing context\n")
    f.write("// {dx_off, dy_off, w, h, step}: dest = anchor + off, size w x h, source step (2.8 fixed)\n")
    place_func(f, "place_pl_s1", [(a, 92 * 2 / 3 / 32, "feet_full") for a in players],
               "Stage 1 player: 92x92 UI px frame (stage1_demo SPR_H*ZOOM), anchor = w2s(px, py+4)")
    place_func(f, "place_pl_s2", [(a, 62 * 2 / 3 / 32, "feet_full") for a in players],
               "Stage 2 player: 62 UI px frame (stage2_demo SPR_H), anchor = (px, py+4)")
    place_func(f, "place_card", [(a, 170 * 2 / 3 / 32, "center") for a in cards],
               "cards: 170x170 UI px, centred in the slot")
    k_ta = 92 * 2 / 3 / ta.h
    k_por = min(84 * 2 / 3 / ta.w, 84 * 2 / 3 / ta.h)
    place_func(f, "place_ta", [(ta, k_ta, "feet_crop")], "TA guide: crop scaled to 92 UI px tall")
    place_func(f, "place_ta_portrait", [(ta, k_por, "center")], "TA portrait: fits 84x84 UI px")
    place_func(f, "place_boss_stand", [(boss, 62 * 2 / 3 / 32, "feet_full")], "Boss standing (62 UI px)")
    place_func(f, "place_grad", [(a, 132 * 2 / 3 / 32, "center") for a in players],
               "ending portrait: player frame 132 UI px tall, centred (load_grad_sprite)")
    place_func(f, "place_card84", [(a, 84 * 2 / 3 / 32, "center") for a in cards],
               "ending card backs: 84x84 UI px, centred")
    # crop_info(id) = {ox[5:0], oy[5:0], w[6:0], h[6:0]} of every P4 picture (stored pixels)
    f.write("function [25:0] crop_info;\n  input [7:0] id;\n  begin\n    case (id)\n")
    for a in ASSETS.values():
        if a.aid is not None and a.kind == "P4":
            f.write("      8'd%d: crop_info = {6'd%d, 6'd%d, 7'd%d, 7'd%d}; // %s\n" % (a.aid, a.ox, a.oy, min(a.w, 127), min(a.h, 127), a.name))
    f.write("      default: crop_info = 26'd0;\n    endcase\n  end\nendfunction\n")
    place_func(f, "place_boss_sit", [(boss, 48 * 2 / 3 / 32, "feet_full")], "Boss sitting (48 UI px)")
    for fname, items in (("place_end_char", END_CHARS), ("place_end_text", END_TEXTS)):
        f.write("function [49:0] %s;\n  input [3:0] e;\n  begin\n    case (e)\n" % fname)
        for i, (im, px, py) in enumerate(items, 1):
            f.write("      4'd%d: %s = {11'sd%d, 10'sd%d, 10'd%d, 9'd%d, 10'd256};\n" % (i, fname, px, py, im.width, im.height))
        f.write("      default: %s = 50'd0;\n    endcase\n  end\nendfunction\n" % fname)

with open(os.path.join(OUT_GEN, "tile_dir.vh"), "w") as f:
    f.write("// generated by fpga/tools/asset_compiler.py - do not edit\n")
    f.write("// tile_dir(t) = {valid, kind(0 P4 / 1 VQ), base[17:0], cbase[12:0], pbase[12:0]}  (46 bits)\n")
    f.write("function [45:0] tile_dir;\n  input [7:0] t;\n  begin\n    case (t)\n")
    for i, (k, a) in enumerate(TILE_KIND):
        if k == "P4":
            f.write("      8'd%d: tile_dir = {1'b1, 1'b0, 18'd%d, 13'd0, 13'd%d};\n" % (i + 1, a.base, a.pal))
        else:
            f.write("      8'd%d: tile_dir = {1'b1, 1'b1, 18'd%d, 13'd%d, 13'd%d};\n" % (i + 1, a.base, a.pal, a.pal_base))
    f.write("      default: tile_dir = 46'd0;\n    endcase\n  end\nendfunction\n")

# --------------------------------------------------------------------------------------
# decode back from the ROM arrays (bit-exact model of the hardware) -> previews + PSNR
# --------------------------------------------------------------------------------------
def pal_rgb(i):
    r, g, b = rom_pal[i]
    return (r * 17, g * 17, b * 17)


def decode(a):
    out = np.zeros((a.h, a.w, 4), dtype=np.uint8)
    for y in range(a.h):
        for x in range(a.w):
            if a.kind == "P4":
                v = rom_p4[a.base + y * a.w + x]
                if v:
                    out[y, x] = pal_rgb(a.pal + v) + (255,)
            else:
                bi = rom_vqi[a.base + (y >> 2) * (a.w >> 2) + (x >> 2)]
                v = rom_cb[(a.pal + bi) * 16 + (y & 3) * 4 + (x & 3)]
                if v:
                    out[y, x] = pal_rgb(a.pal_base + v) + (255,)
    return Image.fromarray(out)


def psnr(a, img):
    x = np.asarray(a.img.convert("RGBA")).astype(float)
    y = np.asarray(img).astype(float)
    m = x[..., 3] >= 128
    if not m.any():
        return 99.0
    mse = ((x[..., :3] - y[..., :3]) ** 2)[m].mean()
    return 99.0 if mse == 0 else 10 * math.log10(255 ** 2 / mse)


quality = {}
for a in ASSETS.values():
    if a.kind == "VQ" and a.group == "TILES":
        continue
    img = decode(a)
    quality[a.name] = psnr(a, img)
    if (a.kind == "VQ" and not a.name.startswith("st_end_")) or a.name.startswith(("pl_f0_front", "card_", "npc_", "logo_")):
        scale = 2 if a.kind == "VQ" and a.w <= 336 else 1
        img.resize((a.w * scale, a.h * scale), Image.NEAREST).save(os.path.join(OUT_PRV, a.name + ".png"))

bg_dec = decode(ASSETS["st_end_bg"])
for i in range(1, 10):
    c = bg_dec.copy()
    _, cx, cy = END_CHARS[i - 1]
    _, tx, ty = END_TEXTS[i - 1]
    c.alpha_composite(decode(ASSETS["st_end_char%d" % i]), (cx, cy))
    c.alpha_composite(decode(ASSETS["st_end_text%d" % i]), (tx, ty))
    c.save(os.path.join(OUT_PRV, "st_ending%d.png" % i))
# Stage 3 levels: reconstruct the first 40 columns of each map from the ROMs
for n in sorted(MAPS):
    W = 40
    canvas = Image.new("RGBA", (W * 32, 11 * 32), (40, 40, 60, 255))
    for r in range(11):
        for c in range(W):
            t = rom_map[LEVEL_BASE[n] + r * 250 + c]
            if not t:
                continue
            k, a = TILE_KIND[t - 1]
            canvas.alpha_composite(decode(a), (c * 32, r * 32))
    canvas.save(os.path.join(OUT_PRV, "level%d_cols0-39.png" % n))

# --------------------------------------------------------------------------------------
# report + budget check
# --------------------------------------------------------------------------------------
lines = ["# Block RAM report (generated by `fpga/tools/asset_compiler.py`)", "",
         "Device: **XC7A100T-1CSG324C (Nexys A7-100T)** - %d x RAMB36E1 = %d Kbit." % (DEVICE_RAMB36, DEVICE_RAMB36 * 36),
         "Each ROM is costed with the cheapest RAMB36 aspect ratio (32Kx1 ... 1Kx36) that holds it.", "",
         "| ROM | depth | width | bits | RAMB36 | config | contents |", "|---|---:|---:|---:|---:|---|---|"]
asset_total = 0
for name, data, width, desc in ROMS:
    n, cfg = ramb36(len(data), width)
    asset_total += n
    lines.append("| `%s.mem` | %d | %d | %d | %s | %s | %s |" % (name, len(data), width, len(data) * width, n, cfg, desc))
lines.append("| **asset ROMs** | | | %d | **%s** | | budget %d |" % (sum(len(d) * w for _, d, w, _ in ROMS), asset_total, BUDGET_RAMB36))
sys_total = 0
for name, depth, width, desc in SYSTEM:
    n, cfg = ramb36(depth, width)
    sys_total += n
    lines.append("| %s | %d | %d | %d | %s | %s | %s |" % (name, depth, width, depth * width, n, cfg, desc))
total = asset_total + sys_total
lines += ["| **TOTAL** | | | | **%s / %d (%.0f%%)** | | |" % (total, DEVICE_RAMB36, 100.0 * total / DEVICE_RAMB36), ""]
raw = 0
for a in ASSETS.values():
    raw += a.w * a.h * 12
lines += ["Uncompressed RGB444 size of the stored pictures: %.1f Mbit (%.0f RAMB36) - "
          "compression factor %.1fx." % (raw / 1e6, raw / 36864, raw / max(1, sum(len(d) * w for _, d, w, _ in ROMS))), ""]
lines += ["## Pictures", "", "| id | name | enc | stored size | PSNR dB | note |", "|---:|---|---|---|---:|---|"]
for a in ASSETS.values():
    if a.name.startswith("tile_"):
        continue
    q = quality.get(a.name)
    lines.append("| %d | %s | %s | %dx%d | %s | %s |" % (a.aid, a.name, a.kind + ("/" + a.group if a.group else ""),
                                                      a.w, a.h, "%.1f" % q if q else "-", a.note))
nvq = sum(1 for k, _ in TILE_KIND if k == "VQ")
lines += ["", "Stage 3 tiles: %d unique 32x32 tiles (%d P4, %d VQ). Levels: %s" %
          (len(TILES), len(TILES) - nvq, nvq, json.dumps(LEVEL_INFO)), ""]
lines += ["Card files with identical pictures share one ROM copy: " +
          ", ".join("%s=%s" % (k, v) for k, v in CARD_ALIAS.items() if k != v), ""]
with open(os.path.join(OUT_DOC, "bram_report.md"), "w") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines[:16 + len(ROMS) + len(SYSTEM)]))
if asset_total > BUDGET_RAMB36 or total > DEVICE_RAMB36:
    raise SystemExit("ERROR: Block RAM budget exceeded (%s asset RAMB36, %s total)" % (asset_total, total))
print("OK: fits (%s of %d RAMB36)" % (total, DEVICE_RAMB36))
