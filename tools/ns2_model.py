#!/usr/bin/env python3
"""The Namco System 2 reference renderer (docs/PLAN.md M0): a whole-frame
model of MAME's screen_update from a captured state, exact against MAME's
pictures before any RTL is judged. It is the specification M1 compares with.

Follows, line for line where it matters:
  namcos2_v.cpp        screen_update (priority order, clip), the tile callbacks
  namco_c123tmap.cpp   six planes, scroll dx/dy, mask ROM transparency
  namco_c116.cpp       the palette layout and the clip registers
  namcos2_roz.cpp      ROZ (A)
  namcos2_sprite.cpp   sprites (A): zdrawgfxzoom into a render bitmap, then the mix

    tools/ns2_model.py SET TRACE_DIR [--frames F ...] [--sweep N]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

W, H = 288, 224


# ------------------------------------------------------------------ gfx decode
def decode(rom, width, height, planes, xoffs, yoffs, charinc, count=None):
    """MAME's gfx_layout decode: bit b of an element is rom byte b//8, bit 7-b%8;
    planeoffset[0] is the pixel's MSB. Returns uint8 [count, height, width]."""
    bits = np.unpackbits(np.frombuffer(rom, np.uint8))           # MSB first, as MAME's readbit
    n = count or (len(rom) * 8) // charinc
    base = (np.arange(n) * charinc)[:, None, None]
    pix = np.zeros((n, height, width), np.uint8)
    yo, xo = np.array(yoffs)[None, :, None], np.array(xoffs)[None, None, :]
    for i, p in enumerate(planes):
        pix |= (bits[base + yo + xo + p] << (len(planes) - 1 - i)).astype(np.uint8)
    return pix


def step(start, inc, n=None):
    return [start + inc * i for i in range(n)]


def raw8x8(rom):
    """gfx_8x8x8_raw: 64 bytes per tile, one byte per pixel, row major."""
    return np.frombuffer(rom, np.uint8).reshape(-1, 8, 8)


def obj32(rom):
    """namcos2.cpp obj_layout: 32x32, 8 bpp, planes STEP8(0,4), x in groups of 4."""
    xo = []
    for g in range(8):
        xo += step(4 * 8 * g, 1, 4)
    return decode(rom, 32, 32, step(0, 4, 8), xo, step(0, 4 * 8 * 8, 32), 32 * 32 * 8)


def masks(rom):
    """The C123 / C169 mask ROM: 8 bytes per 8x8 tile, MSB = leftmost pixel."""
    return np.unpackbits(np.frombuffer(rom, np.uint8)).reshape(-1, 8, 8).astype(bool)


class Roms:
    def __init__(self, name):
        regions, _ = R.build(name)
        for tag, fn in R.WIRING.get(R.games()[name]['init'], {}).items():
            regions[tag] = fn(regions[tag])
        self.tiles = raw8x8(regions['c123tmap'])
        self.tmask = masks(regions['c123tmap:mask'])
        self.roz = raw8x8(regions['s2roz']) if 's2roz' in regions else None
        cfg = R.games()[name]['config']
        if cfg == 'metlhawk':
            # GFXLAYOUT_RAW 32x32 and its xy-swapped twin (rot90 sprites)
            raw = np.frombuffer(regions['sprite'], np.uint8).reshape(-1, 32, 32)
            self.spr, self.spr_rot = raw, raw.transpose(0, 2, 1)
        else:
            self.spr = obj32(regions['sprite']) if 'sprite' in regions else None
        # C355: gfx_16x16x8_raw; C45: its 256-byte CLUT
        self.c355 = np.frombuffer(regions['c355spr'], np.uint8).reshape(-1, 16, 16) if 'c355spr' in regions else None
        self.clut = np.frombuffer(regions['c45_road:clut'], np.uint8).astype(np.int64) if 'c45_road:clut' in regions else None
        self.cfg = cfg
        # namcos2_sprite_finallap_device: the older sprite board (NS2-5)
        self.spr_fl = cfg == 'finallap'
        self.tile_cb = tile_cb_fl2 if cfg in ('finalap2', 'finalap3') else tile_cb_std
        # C169: gfx_16x16x8_raw and a 32-byte 1 bpp mask per tile
        self.c169 = np.frombuffer(regions['c169roz'], np.uint8).reshape(-1, 16, 16) if 'c169roz' in regions else None
        self.c169mask = (np.unpackbits(np.frombuffer(regions['c169roz:mask'], np.uint8)).reshape(-1, 16, 16).astype(bool)
                         if 'c169roz:mask' in regions else None)


# ------------------------------------------------------------------ state
class State:
    def __init__(self, path, blocks):
        raw = np.frombuffer(open(path, 'rb').read(), '>u2')
        self.b, off = {}, 0
        for name, addr, n in blocks:
            self.b[name] = raw[off:off + n].astype(np.int64)
            off += n
        pal = self.b['pal'] & 0xff                      # C116: one byte per 16-bit word
        o = np.arange(0x8000)
        plane = (o & 0x1800) >> 11
        color = ((o & 0x6000) >> 2) | (o & 0x7ff)
        self.rgb = np.zeros((0x2000, 3), np.int64)
        for p in range(3):
            sel = plane == p
            self.rgb[color[sel], p] = pal[sel]
        self.c116 = [(int(pal[0x1800 + 2 * r]) << 8) | int(pal[0x1801 + 2 * r]) for r in range(8)]


def read_blocks(trace):
    out = []
    for line in open(os.path.join(trace, 'blocks.txt')):
        n, a, c = line.split()
        out.append((n, int(a, 16), int(c)))
    return out


# ------------------------------------------------------------------ layers
def tilemap_layer(r, st, i, cb):
    """(pen, opaque) for C123 plane i over the 288x224 screen."""
    ctl = st.b['tctl']
    vram = st.b['tmap']
    flip = bool(ctl[1] & 0x8000)
    ys, xs = np.mgrid[0:H, 0:W]
    # MAME's tilemap scroll (set_scrolldx(-dx, 288 + dx), set_scrolldy(-24, 224 + 24);
    # flip negates the scroll and mirrors the pixmap): unflipped, screen x shows
    # map x + scroll + dx; flipped, map 511 - (x + scroll + dx) (the same sum)
    if i < 4:
        sx, sy = int(ctl[4 * i + 1]) & 0x1ff, int(ctl[4 * i + 3]) & 0x1ff
        dx = 44 + (4, 2, 1, 0)[i]
        tx = (xs + sx + dx) % 512
        ty = (ys + sy + 24) % 512
        if flip:
            tx, ty = 511 - tx, 511 - ty
        code = vram[i * 0x1000 + (ty // 8) * 64 + tx // 8]
    else:
        tx, ty = (W - 1 - xs, H - 1 - ys) if flip else (xs, ys)
        code = vram[(0x4008, 0x4408)[i - 4] + (ty // 8) * 36 + tx // 8]
    tile, mask = cb(code), code
    pen = r.tiles[tile, ty % 8, tx % 8]
    opaque = r.tmask[mask, ty % 8, tx % 8]
    color = 16 * 256 + ((int(ctl[0x18 + i]) & 7) << 8)
    return pen.astype(np.int64) + color, opaque


def tile_cb_std(code):
    """TilemapCB: bitswap<16>(code, 13,12,11,15,14,10..0)."""
    c = code
    return (((c >> 13) & 1) << 15) | (((c >> 12) & 1) << 14) | (((c >> 11) & 1) << 13) | \
           (((c >> 15) & 1) << 12) | (((c >> 14) & 1) << 11) | (c & 0x7ff)


def tile_cb_fl2(code):
    """TilemapCB_finalap2: bitswap<15>(code, 13,12,11,14,10..0)"""
    c = code
    return (((c >> 13) & 1) << 14) | (((c >> 12) & 1) << 13) | (((c >> 11) & 1) << 12) | \
           (((c >> 14) & 1) << 11) | (c & 0x7ff)


def roz_layer(r, st):
    """namcos2_roz_device::draw_roz: (pen, opaque) over the screen."""
    ctl = [int(v) for v in st.b['rozctl']]
    s16 = lambda v: v - 0x10000 if v & 0x8000 else v
    incxx, incxy, incyx, incyy = (s16(ctl[k]) for k in range(4))
    startx, starty = s16(ctl[4]), s16(ctl[5])
    size, wrap = 2048, True
    if ctl[7] in (0x4488, 0x44cc):
        wrap = False
    elif ctl[7] == 0x44ee:
        wrap, size = False, 256
    startx = ((startx << 4) + 38 * incxx) << 8
    starty = ((starty << 4) + 38 * incxy) << 8
    incxx, incxy, incyx, incyy = (v << 8 for v in (incxx, incxy, incyx, incyy))
    ys, xs = np.mgrid[0:H, 0:W]
    srcx = (startx + xs * incxx + ys * incyx) & 0xffffffff
    srcy = (starty + xs * incxy + ys * incyy) & 0xffffffff
    xpos, ypos = srcx >> 16, srcy >> 16
    if wrap:
        xpos &= size - 1
        ypos &= size - 1
        inside = np.ones_like(xpos, bool)
    else:
        inside = (xpos <= size) & (ypos < size)
        xpos = np.minimum(xpos, 2047)
        ypos = np.minimum(ypos, 2047)
    code = st.b['roz'][(ypos // 8) * 256 + xpos // 8]
    pen = r.roz[code % len(r.roz), ypos % 8, xpos % 8].astype(np.int64)
    color = int(st.b['gfxctl'][0]) & 0x0f00
    return pen + color, inside & (pen != 0xff)


def zdraw(out, img, color, flipx, flipy, sx, sy, scalex, scaley, prival, clip):
    """namcos2_sprite_device::zdrawgfxzoom into the render bitmap `out`
    (0xffff = empty): img is the (source-clipped) element, pen 0xff clear"""
    x0, x1, y0, y1 = clip
    if not (scalex and scaley):
        return
    gh, gw = img.shape
    sw, sh = (scalex * gw + 0x8000) >> 16, (scaley * gh + 0x8000) >> 16
    if not (sw and sh):
        return
    dx, dy = (gw << 16) // sw, (gh << 16) // sh
    xib, yi = 0, 0
    if flipx:
        xib, dx = (sw - 1) * dx, -dx
    if flipy:
        yi, dy = (sh - 1) * dy, -dy
    ex, ey = sx + sw, sy + sh
    if sx < x0:
        xib += (x0 - sx) * dx; sx = x0
    if sy < y0:
        yi += (y0 - sy) * dy; sy = y0
    ex, ey = min(ex, x1 + 1), min(ey, y1 + 1)
    if ex <= sx:
        return
    for y in range(sy, ey):
        row = img[yi >> 16]
        xi = xib + dx * np.arange(ex - sx)
        c = row[xi >> 16].astype(np.int64)
        m = c != 0xff
        seg = out[y, sx:ex]
        seg[m] = ((prival & 0xf) << 12) | ((color * 256 + c[m]) & 0xfff)
        yi += dy


def sprites_a(r, st, clip, pri_mask=0x7):
    """(render bitmap, 0xffff = empty) as namcos2_sprite_device::draw_sprites."""
    spr = st.b['spr']
    ctrl = int(st.b['gfxctl'][0])
    out = np.full((H, W), 0xffff, np.int64)
    base = (ctrl & 0xf) * 128 * 4
    for loop in range(128):
        w0, w1, w2, w3 = (int(spr[base + loop * 4 + k]) for k in range(4))
        sizey = ((w0 >> 10) & 0x3f) + 1
        if getattr(r, 'spr_fl', False):
            # namcos2_sprite_finallap_device::get_tilenum_and_size
            sprn, is32 = (w1 >> 2) & 0x7ff, bool(w1 & 0x2000)
        else:
            sprn, is32 = (w1 >> 2) & 0xfff, bool(w0 & 0x200)
        sizex = (w3 >> 10) & 0x3f
        if not is32:
            sizex >>= 1
        if not ((sizey - 1) and sizex):
            continue
        scalex = (sizex << 16) // (0x20 if is32 else 0x10)
        scaley = (sizey << 16) // (0x20 if is32 else 0x10)
        gfx = r.spr[sprn % len(r.spr)]
        if not is32:
            qx, qy = (16 if w1 & 1 else 0), (16 if w1 & 2 else 0)
            gfx = gfx[qy:qy + 16, qx:qx + 16]
        zdraw(out, gfx, (w3 >> 4) & 0xf, bool(w1 & 0x4000), bool(w1 & 0x8000),
              (w2 & 0x7ff) - 0x50 + 0x07, (0x1ff - (w0 & 0x1ff)) - 0x50 + 0x02,
              scalex, scaley, w3 & pri_mask, clip)   # namcos2_state: pri & 7; finallap: 4 bits
    return out


def sprites_mh(r, st, clip):
    """namcos2_sprite_metalhawk_device::draw_sprites: 8 words a sprite, no
    bank; rot90 selects the xy-swapped decode; pri is 4 bits"""
    spr = st.b['spr']
    out = np.full((H, W), 0xffff, np.int64)
    for loop in range(128):
        w = [int(spr[loop * 8 + k]) for k in range(8)]
        sizey = ((w[0] >> 10) & 0x3f) + 1
        sizex = (w[3] >> 10) & 0x3f
        if not ((sizey - 1) and sizex):
            continue
        attrs, tile, flags = w[7], w[1], w[6]
        sprn = (tile >> 2) & 0xfff
        big = bool(flags & 8)
        sx = (w[3] & 0x3ff) - 0x50 + 0x07
        sy = (0x1ff - (w[0] & 0x1ff)) - 0x50 + 0x02
        scalex = (sizex << 16) // 0x20
        scaley = (sizey << 16) // (0x20 if big else 0x10)
        gfx = (r.spr_rot if flags & 1 else r.spr)
        img = gfx[sprn % len(gfx)]
        if big:
            if sizex < 0x20:
                sx -= (0x20 - sizex) // 8
            if sizey < 0x20:
                sy += (0x20 - sizey) // 0xc
        else:
            qx, qy = (16 if tile & 1 else 0), (16 if tile & 2 else 0)
            img = img[qy:qy + 16, qx:qx + 16]
        zdraw(out, img, (attrs >> 4) & 0xf, bool(flags & 2), bool(flags & 4), sx, sy, scalex, scaley, attrs & 0xf, clip)
    return out


# ------------------------------------------------------------------ C169 ROZ
def c169_params(src):
    """namco_c169roz_device::unpack_params (words 1..7 of a layer's set)"""
    def s12(t):
        return (t | 0xf000) - 0x10000 if t & 0x8000 else t & 0x0fff
    def s16(v):
        return v - 0x10000 if v & 0x8000 else v
    a = src[1]
    p = dict(wrap=not (a & 0x800), size=512 << ((a & 0x300) >> 8), color=(a & 0xf) * 256,
             priority=(a & 0xf0) >> 4, left=(src[2] & 0x7000) >> 3, top=(src[3] & 0x7000) >> 3,
             incxx=s12(src[2]), incxy=s12(src[3]), incyx=s12(src[4]), incyy=s12(src[5]))
    sx, sy = s16(src[6]) << 4, s16(src[7]) << 4
    sx += 36 * p['incxx'] + 3 * p['incyx']
    sy += 36 * p['incxy'] + 3 * p['incyy']
    p['startx'], p['starty'] = sx << 8, sy << 8
    for k in ('incxx', 'incxy', 'incyx', 'incyy'):
        p[k] <<= 8
    return p


def c169_tile_mh(data):
    """RozCB_metlhawk: tile = bitswap<13>(code, 11,10,9,12,8..0), mask = code"""
    c = data & 0x1fff
    tile = (((c >> 11) & 1) << 12) | (((c >> 10) & 1) << 11) | (((c >> 9) & 1) << 10) | \
           (((c >> 12) & 1) << 9) | (c & 0x1ff)
    return tile, data


def c169_rows(r, st, p, ys, cb):
    """draw_helper over screen rows ys: (pen + colour, opaque) of shape (len(ys), W)"""
    vram = st.b['c169']
    ys = np.asarray(ys)[:, None]
    xs = np.arange(W)[None, :]
    cx = (p['startx'] + xs * p['incxx'] + ys * p['incyx']) & 0xffffffff
    cy = (p['starty'] + xs * p['incxy'] + ys * p['incyy']) & 0xffffffff
    m = p['size'] - 1
    xpos = (((cx >> 16) & m) + p['left']) & 0xfff
    ypos = (((cy >> 16) & m) + p['top']) & 0xfff
    col, row = xpos >> 4, ypos >> 4
    idx = ((col & 0x80) << 8) | ((row & 0xff) << 7) | (col & 0x7f)
    data = vram[idx & 0x7fff] & 0x3fff
    tile, mask = cb(data)
    pen = r.c169[tile % len(r.c169), ypos & 15, xpos & 15].astype(np.int64)
    op = r.c169mask[mask % len(r.c169mask), ypos & 15, xpos & 15]
    return pen + p['color'], op


def draw_c169(r, st, rc, pv, dest, pri, inclip, rows, cb):
    """namco_c169roz_device::draw for priority pv: layer 1 then 0; layer 1
    takes per-line parameters from video RAM when control word 0 is 0x8000"""
    vram = st.b['c169']
    for which in (1, 0):
        src = rc[which * 8:which * 8 + 8]
        if src[1] & 0x8000:
            continue
        if which == 1 and rc[0] == 0x8000:
            for y in range(rows[0], rows[1] + 1):
                o = ((y >> 3) * 0x100 + (y & 7) * 0x10 + 0xe080) // 2
                ls = [int(v) for v in vram[o:o + 8]]
                if ls[1] & 0x8000:
                    continue
                p = c169_params(ls)
                if p['priority'] != pv:
                    continue
                pen, op = c169_rows(r, st, p, [y], cb)
                m = op[0] & inclip[y]
                dest[y][m] = pen[0][m]; pri[y][m] = pv
        else:
            p = c169_params(src)
            if p['priority'] == pv:
                pen, op = c169_rows(r, st, p, range(H), cb)
                m = op & inclip
                dest[m] = pen[m]; pri[m] = pv


def render_mh(r, st, pal=None):
    """metlhawk_state::screen_update_metlhawk: priorities 0..15; the C123
    planes of priority p draw at 2p, a C169 layer at its own priority;
    sprites (4-bit priority) over whatever has priority <= theirs"""
    pal = pal or st
    black = -1
    dest = np.full((H, W), black, np.int64)
    pri = np.zeros((H, W), np.int64)
    reg = st.c116
    x0, x1, y0, y1 = max(reg[0] - 0x4a, 0), min(reg[1] - 0x4a - 1, W - 1), max(reg[2] - 0x21, 0), min(reg[3] - 0x21 - 1, H - 1)
    inclip = np.zeros((H, W), bool)
    if x1 >= x0 and y1 >= y0:
        inclip[y0:y1 + 1, x0:x1 + 1] = True
    ctl = st.b['tctl']
    rc = [int(v) for v in st.b['c169ctl']]
    vram = st.b['c169']
    layers = {}
    for pv in range(16):
        if pv % 2 == 0:
            for i in range(6):
                lp = int(ctl[0x10 + i])
                if (lp & 7) == pv // 2 and not (lp & 8):
                    if i not in layers:
                        layers[i] = tilemap_layer(r, st, i, tile_cb_std)
                    pen, op = layers[i]
                    m = op & inclip
                    dest[m] = pen[m]; pri[m] = pv
        draw_c169(r, st, rc, pv, dest, pri, inclip, (y0, y1), c169_tile_mh)
    spr = sprites_mh(r, st, (x0, x1, y0, y1))
    return mix(spr, dest, pri, inclip, pal, black)


def c169_tile_lw(data):
    """RozCB_luckywld: bitswap<11>(code & 0x31ff, 13,12,8..0), then by bits 11-9"""
    c = data & 0x31ff
    mangle = (((c >> 13) & 1) << 10) | (((c >> 12) & 1) << 9) | (c & 0x1ff)
    k = (data >> 9) & 7
    mangle = np.where(k == 0, mangle + 0x1c00, np.where(k == 1, mangle | 0x800, mangle))
    return mangle, data


# ------------------------------------------------------------------ C45 road
def road_line(r, st, y):
    """namco_c45_road_device::draw for screen line y: (priority, x0, pens) or None"""
    road = st.b['road']
    line = road[0xfd00:]
    screenx = int(line[y + 15])
    zoomx = int(line[0x200 + y + 15]) & 0x3ff
    if zoomx == 0:
        return None
    sourcey = (int(line[0x100 + y + 15]) + int(line[0x1ff])) & 0x1fff
    dsx = (1024 << 16) // zoomx
    if dsx == 0:
        return None
    sx = screenx & 0xfff
    sx = (sx - 0x1000 if sx & 0x800 else sx) - 72
    n = (44 * 16 << 16) // dsx
    srcx = (np.arange(n) * dsx) >> 16
    # the source row: 64 tiles of 16 x 16, 2 bpp, in RAM (big-endian words)
    tmap = road[:0x8000]
    data = tmap[(sourcey >> 4) * 64 + ((srcx >> 4) & 63)]
    tile, color = (data & 0x3ff) % 1000, data >> 10
    tr, px = sourcey & 15, srcx & 15
    w = road[0x8000 + tile * 32 + tr * 2 + (px >> 3)]
    b = px & 7
    pix = (((w >> (15 - b)) & 1) << 1) | ((w >> (7 - b)) & 1)
    pen = 0xf00 + color * 4 + pix
    if r.clut is not None:
        pen = (pen & ~0xff) | r.clut[pen & 0xff]
    return (screenx & 0xf000) >> 12, sx, pen


def draw_road(r, st, pv, dest, pri, inclip):
    for y in range(H):
        rl = road_line(r, st, y)
        if rl is None or rl[0] != pv:
            continue
        _, sx, pen = rl
        xs = sx + np.arange(len(pen))
        ok = (xs >= 0) & (xs < W)
        xs, pen = xs[ok], pen[ok]
        m = inclip[y, xs]
        dest[y, xs[m]] = pen[m]; pri[y, xs[m]] = pv


# ------------------------------------------------------------------ C355 sprites
def sprites_c355(r, st, clip):
    """namco_c355spr_device: the list at 0x2000 (to bit 8), each sprite's
    format and tiles, zoomed tile by tile, windowed; later over earlier"""
    ram = st.b['c355']
    pos = st.b['c355pos'] if 'c355pos' in st.b else np.zeros(4, np.int64)
    sext = lambda v, b: (v & ((1 << b) - 1)) - ((v & (1 << (b - 1))) << 1)
    xscroll, yscroll = sext(int(pos[1]), 9) + 0x26, sext(int(pos[0]), 9) + 0x19
    out = np.full((H, W), 0xffff, np.int64)
    X0, X1, Y0, Y1 = clip
    for i in range(256):
        which = int(ram[0x1000 + i])
        t = [int(ram[((which & 0xff) << 3) + a]) for a in range(8)]
        last = which & 0x100
        palette = t[6]
        prio = (palette >> 4) & 0xf
        fmt_i = t[0] & 0x7ff
        offset = t[1]
        hpos, vpos, hsize, vsize = t[2] - xscroll, t[3] - yscroll, t[4], t[5]
        ce = (palette >> 8) & 0xf
        ct = [int(ram[0x1200 + (ce << 2) + a]) for a in range(4)]
        cx0, cx1, cy0, cy1 = ct[0] - xscroll, ct[1] - xscroll, ct[2] - yscroll, ct[3] - yscroll
        hpos, vpos = sext(hpos & 0x7ff, 11), sext(vpos & 0x7ff, 11)
        f = [int(ram[0x2000 + (fmt_i << 2) + a]) for a in range(4)]
        tile_index, fmt, dx, dy = f[0], f[1], f[2] & 0x1ff, f[3] & 0x1ff
        ncols, nrows = (fmt >> 4) & 0xf or 16, fmt & 0xf or 16
        flipx, flipy = bool(hsize & 0x8000), bool(vsize & 0x8000)
        hsize, vsize = hsize & 0x3ff, vsize & 0x3ff
        if hsize and vsize:
            zx = (hsize << 16) // (ncols * 16)
            dxz = ((dx & 0xff) * zx + 0x8000) >> 16
            hpos = hpos + (dxz if flipx else -dxz) * (-1 if dx & 0x100 else 1)
            zy = (vsize << 16) // (nrows * 16)
            dyz = ((dy & 0xff) * zy + 0x8000) >> 16
            vpos = vpos + (dyz if flipy else -dyz) * (-1 if dy & 0x100 else 1)
            sclip = (max(cx0, X0), min(cx1, X1), max(cy0, Y0), min(cy1, Y1))
            color = palette & 0xf
            shr, ssr = vsize, nrows * 16
            y = vpos
            for row in range(nrows):
                th = 16 * shr // ssr
                zoomy = (shr << 16) // ssr
                if flipy:
                    y -= th
                swr, ssw = hsize, ncols * 16
                x = hpos
                for col in range(ncols):
                    tw = 16 * swr // ssw
                    zoomx = (swr << 16) // ssw
                    if flipx:
                        x -= tw
                    tile = int(ram[0x4000 + ((tile_index + row * ncols + col) & 0xffff)]) if tile_index + row * ncols + col < 0x6100 else 0
                    if not tile & 0x8000:
                        sw_, sh_ = (zoomx * 16 + 0x8000) >> 16, (zoomy * 16 + 0x8000) >> 16
                        c355_zdraw(out, r.c355[(tile + offset) % len(r.c355)], color, flipx, flipy, x, y, sw_, sh_, prio, sclip)
                    if not flipx:
                        x += tw
                    swr -= tw; ssw -= 16
                if not flipy:
                    y += th
                shr -= th; ssr -= 16
        if last:
            break
    return out


def c355_zdraw(out, img, color, flipx, flipy, sx, sy, sw, sh, prival, clip):
    """namco_c355spr_device::zdrawgfxzoom (the screen size given)"""
    x0, x1, y0, y1 = clip
    if not (sw and sh):
        return
    dx, dy = (16 << 16) // sw, (16 << 16) // sh
    xib, yi = 0, 0
    if flipx:
        xib, dx = (sw - 1) * dx, -dx
    if flipy:
        yi, dy = (sh - 1) * dy, -dy
    ex, ey = sx + sw, sy + sh
    if sx < x0:
        xib += (x0 - sx) * dx; sx = x0
    if sy < y0:
        yi += (y0 - sy) * dy; sy = y0
    ex, ey = min(ex, x1 + 1), min(ey, y1 + 1)
    if ex <= sx:
        return
    for y in range(sy, ey):
        row = img[yi >> 16]
        c = row[(xib + dx * np.arange(ex - sx)) >> 16].astype(np.int64)
        m = c != 0xff
        seg = out[y, sx:ex]
        seg[m] = ((prival & 0xf) << 12) | ((color * 256 + c[m]) & 0xfff)
        yi += dy


def render_board(r, st, pal, board):
    """finallap / sgunner / suzuka8h (luckywld) screen updates: priorities
    0..15 (sgunner 0..7), C123 planes at 2p, road and C169 at their own;
    then the sprites (A with 4-bit priority, or C355)"""
    black = -1
    dest = np.full((H, W), black, np.int64)
    pri = np.zeros((H, W), np.int64)
    reg = st.c116
    x0, x1, y0, y1 = max(reg[0] - 0x4a, 0), min(reg[1] - 0x4a - 1, W - 1), max(reg[2] - 0x21, 0), min(reg[3] - 0x21 - 1, H - 1)
    inclip = np.zeros((H, W), bool)
    if x1 >= x0 and y1 >= y0:
        inclip[y0:y1 + 1, x0:x1 + 1] = True
    ctl = st.b['tctl']
    layers = {}
    def planes(p, pv):
        for i in range(6):
            lp = int(ctl[0x10 + i])
            if (lp & 7) == p and not (lp & 8):
                if i not in layers:
                    layers[i] = tilemap_layer(r, st, i, r.tile_cb)
                pen, op = layers[i]
                m = op & inclip
                dest[m] = pen[m]; pri[m] = pv
    if board == 'sg':
        for p in range(8):
            planes(p, p)
    else:
        rc = [int(v) for v in st.b['c169ctl']] if 'c169ctl' in st.b else None
        for pv in range(16):
            if pv % 2 == 0:
                planes(pv // 2, pv)
            draw_road(r, st, pv, dest, pri, inclip)
            if rc is not None:
                draw_c169(r, st, rc, pv, dest, pri, inclip, (y0, y1), c169_tile_lw)
    if board == 'fl':
        spr = sprites_a(r, st, (x0, x1, y0, y1), pri_mask=0xf)
        return mix(spr, dest, pri, inclip, pal, black)
    spr = sprites_c355(r, st, (x0, x1, y0, y1))
    # sgunner_state::sprite_mix_callback_c355: pen 0xffe sets 0x800 whatever is there
    has = (spr != 0xffff) & inclip
    c = spr & 0xfff
    m = has & (pri <= ((spr >> 12) & 0xf)) & ((c & 0xff) != 0xff)
    shadow = m & (c == 0xffe)
    dest[m & ~shadow] = c[m & ~shadow]
    dest[shadow & (dest >= 0)] |= 0x800
    rgb = np.zeros((H, W), np.uint32)
    ok = dest >= 0
    col = pal.rgb[dest[ok] & 0x1fff]
    rgb[ok] = (col[:, 0] << 16) | (col[:, 1] << 8) | col[:, 2]
    return rgb


def mix(spr, dest, pri, inclip, pal, black):
    """the sprite mix callback (namcos2 / metlhawk): the sprite where the
    pixel's priority <= its own; pen 0xffe shadows"""
    has = (spr != 0xffff) & inclip
    srcpri = (spr >> 12) & 0xf
    c = spr & 0xfff
    m = has & (pri <= srcpri) & ((c & 0xff) != 0xff)
    shadow = m & (c == 0xffe)
    normal = m & ~shadow
    dest = dest.copy()
    dest[normal] = c[normal]
    up = shadow & (dest >= 0) & ((dest & 0x1000) != 0)
    dest[up] |= 0x800
    dest[shadow & ~up] = black
    rgb = np.zeros((H, W), np.uint32)
    ok = dest >= 0
    col = pal.rgb[dest[ok] & 0x1fff]
    rgb[ok] = (col[:, 0] << 16) | (col[:, 1] << 8) | col[:, 2]
    return rgb


# ------------------------------------------------------------------ screen
def render(r, st, board='std', pal=None):
    """namcos2_state::screen_update -> RGB (H, W) uint32. `pal`: the State whose
    palette colours the picture (NS2-2: MAME's picture F+1 is state F's
    composition with state F+1's palette, as GN-2 / MS1Z-5)."""
    if 'c169' in st.b and 'spr' in st.b:
        return render_mh(r, st, pal)
    if 'road' in st.b and 'spr' in st.b:
        return render_board(r, st, pal or st, 'fl')
    if 'c355' in st.b:
        return render_board(r, st, pal or st, 'lw' if 'road' in st.b else 'sg')
    pal = pal or st
    # MAME's black_pen() for the C116 is the palette's own black entry
    # (palette_t::black_entry(), 0x2000 x groups, below 65536): an empty pixel
    # is true black whatever pen 0 holds (NS2-2); -1 stands for it here
    black = -1
    dest = np.full((H, W), black, np.int64)
    pri = np.zeros((H, W), np.int64)
    reg = st.c116
    x0, x1 = reg[0] - 0x4a, reg[1] - 0x4a - 1
    y0, y1 = reg[2] - 0x21, reg[3] - 0x21 - 1
    x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, W - 1), min(y1, H - 1)
    inclip = np.zeros((H, W), bool)
    if x1 >= x0 and y1 >= y0:
        inclip[y0:y1 + 1, x0:x1 + 1] = True
    ctl = st.b['tctl']
    layers = {}
    gfx_ctrl = int(st.b['gfxctl'][0])
    for p in range(8):
        for i in range(6):
            lp = int(ctl[0x10 + i])
            if (lp & 7) == p and not (lp & 8):
                if i not in layers:
                    layers[i] = tilemap_layer(r, st, i, tile_cb_std)
                pen, op = layers[i]
                m = op & inclip
                dest[m] = pen[m]; pri[m] = p
        if ((gfx_ctrl & 0x7000) >> 12) == p:
            pen, op = roz_layer(r, st)
            m = op & inclip
            dest[m] = pen[m]; pri[m] = p
    spr = sprites_a(r, st, (x0, x1, y0, y1))
    has = (spr != 0xffff) & inclip
    srcpri = (spr >> 12) & 0xf
    c = spr & 0xfff
    m = has & (pri <= srcpri) & ((c & 0xff) != 0xff)
    shadow = m & (c == 0xffe)
    normal = m & ~shadow
    dest[normal] = c[normal]
    dest[shadow & (dest >= 0) & ((dest & 0x1000) != 0)] |= 0x800
    dest[shadow & ~((dest >= 0) & ((dest & 0x1000) != 0))] = black
    rgb = np.zeros((H, W), np.uint32)
    ok = dest >= 0
    col = pal.rgb[dest[ok] & 0x1fff]
    rgb[ok] = (col[:, 0] << 16) | (col[:, 1] << 8) | col[:, 2]
    return rgb


# ------------------------------------------------------------------ MAME's banding
# MAME draws a picture in bands: namcos2_base_state::screen_scanline calls
# update_partial(P) at the scanline P = (C116 reg 5 - 32) & 0xff (P - 1 for the
# sets with m_update_to_line_before_posirq), and the rest at the end. The
# picture F+1 is drawn during frame F (NS2-2), so a band uses the registers as
# they were when MAME reached it: state F-1 plus the writes logged in frame F
# before that scanline. VRAM is taken from state F (register splits only).
BEFORE_POSIRQ = {'init_burnforc', 'init_suzuk8h2'}
BUFFERED_C355 = {'suzuka8h', 'luckywld'}
REGBLOCKS = ('tctl', 'pal', 'gfxctl', 'rozctl', 'c169ctl', 'c355pos')


def read_regs(trace):
    out = {}
    p = os.path.join(trace, 'regs.txt')
    if os.path.exists(p):
        for line in open(p):
            F, ln, a, d, m = line.split()[:5]
            out.setdefault(int(F), []).append((int(ln), int(a, 16), int(d, 16), int(m, 16)))
    return out


def order(line):
    """time order of a line within a frame period (frame_done is at line 224)"""
    return (line - 224) % 264


def apply_writes(st, blocks, writes):
    import copy
    n = copy.copy(st)
    n.b = dict(st.b)
    for name in REGBLOCKS:
        if name in n.b:
            n.b[name] = n.b[name].copy()
    addr = {name: (a, c) for name, a, c in blocks}
    for ln, a, d, m in writes:
        for name in REGBLOCKS:
            if name in addr and addr[name][0] <= a < addr[name][0] + 2 * addr[name][1]:
                i = (a - addr[name][0]) // 2
                n.b[name][i] = (int(n.b[name][i]) & ~m) | (d & m)
    pal = n.b['pal'] & 0xff
    n.c116 = [(int(pal[0x1800 + 2 * r]) << 8) | int(pal[0x1801 + 2 * r]) for r in range(8)]
    return n


def render_banded(r, st_prev, st, pal, writes, blocks, before=False):
    """picture F+1 from state F-1 (st_prev), state F (st) and frame F's register writes"""
    writes = sorted(writes, key=lambda w: order(w[0]))
    out = np.zeros((H, W), np.uint32)
    top = 0
    for s in range(H):
        at = apply_writes(st_prev, blocks, [w for w in writes if order(w[0]) < order(s)])
        at.b.update({k: v for k, v in st.b.items() if k not in REGBLOCKS})
        P = (at.c116[5] - 32) & 0xff
        if s == P:
            last = P - 1 if before else P
            if last >= top:
                band = render(r, at, pal=pal)
                out[top:last + 1] = band[top:last + 1]
                top = last + 1
    if top < H:
        out[top:] = render(r, st, pal=pal)[top:]
    return out


def picture(trace, F):
    p = os.path.join(trace, f'p{F:05d}.raw')
    return np.fromfile(p, '<u4').reshape(H, W) & 0xffffff if os.path.exists(p) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set'); ap.add_argument('trace'); ap.add_argument('--frames', type=int, nargs='*')
    a = ap.parse_args()
    r = Roms(a.set)
    blocks = read_blocks(a.trace)
    regs = read_regs(a.trace)
    # NS2-2: MAME's picture F is the composition of state F-1 (as MP-1, MS1Z-5)
    have = set(int(f[1:6]) for f in os.listdir(a.trace) if f.startswith('s') and f.endswith('.bin'))
    frames = a.frames or sorted(F for F in have if F + 1 <= max(have) and os.path.exists(os.path.join(a.trace, f'p{F + 1:05d}.raw')))
    exact = 0
    for F in frames:
        st = State(os.path.join(a.trace, f's{F:05d}.bin'), blocks)
        if R.games()[a.set]['config'] in BUFFERED_C355 and os.path.exists(os.path.join(a.trace, f's{F - 1:05d}.bin')):
            # the C355 builds its list at vblank (set_buffer(1)): the picture
            # shows the sprites of the state before (NS2-5)
            sp = State(os.path.join(a.trace, f's{F - 1:05d}.bin'), blocks)
            for k in ('c355', 'c355pos'):
                st.b[k] = sp.b[k]
        nxt = os.path.join(a.trace, f's{F + 1:05d}.bin')
        pal = State(nxt, blocks) if os.path.exists(nxt) else None
        prv = os.path.join(a.trace, f's{F - 1:05d}.bin')
        if regs.get(F) and os.path.exists(prv):
            out = render_banded(r, State(prv, blocks), st, pal, regs[F], blocks,
                                R.games()[a.set]['init'] in BEFORE_POSIRQ)
        else:
            out = render(r, st, pal=pal)
        pic = picture(a.trace, F + 1)
        d = int((out != pic).sum())
        exact += d == 0
        print(f'state {F} vs picture {F + 1}: {d} pixels differ')
    print(f'{exact} / {len(frames)} exact')


if __name__ == '__main__':
    main()
