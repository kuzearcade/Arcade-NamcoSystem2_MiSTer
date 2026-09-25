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
        self.spr = obj32(regions['sprite']) if 'sprite' in regions else None


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


def sprites_a(r, st, clip):
    """(render bitmap, 0xffff = empty) as namcos2_sprite_device::draw_sprites."""
    spr = st.b['spr']
    ctrl = int(st.b['gfxctl'][0])
    out = np.full((H, W), 0xffff, np.int64)
    x0, x1, y0, y1 = clip
    base = (ctrl & 0xf) * 128 * 4
    for loop in range(128):
        w0, w1, w2, w3 = (int(spr[base + loop * 4 + k]) for k in range(4))
        sizey = ((w0 >> 10) & 0x3f) + 1
        sprn, is32 = (w1 >> 2) & 0xfff, bool(w0 & 0x200)
        sizex = (w3 >> 10) & 0x3f
        if not is32:
            sizex >>= 1
        if not ((sizey - 1) and sizex):
            continue
        scalex = (sizex << 16) // (0x20 if is32 else 0x10)
        scaley = (sizey << 16) // (0x20 if is32 else 0x10)
        if not (scalex and scaley):
            continue
        prival = w3 & 0x7                              # namcos2_state: pri & 7
        color = (w3 >> 4) & 0xf
        ypos = (0x1ff - (w0 & 0x1ff)) - 0x50 + 0x02
        xpos = (w2 & 0x7ff) - 0x50 + 0x07
        flipy, flipx = bool(w1 & 0x8000), bool(w1 & 0x4000)
        gfx = r.spr[sprn % len(r.spr)]
        if not is32:
            qx, qy = (16 if w1 & 1 else 0), (16 if w1 & 2 else 0)
            gfx = gfx[qy:qy + 16, qx:qx + 16]
        gw = gh = 32 if is32 else 16
        sw, sh = (scalex * gw + 0x8000) >> 16, (scaley * gh + 0x8000) >> 16
        if not (sw and sh):
            continue
        dx, dy = (gw << 16) // sw, (gh << 16) // sh
        xib, yi = 0, 0
        if flipx:
            xib, dx = (sw - 1) * dx, -dx
        if flipy:
            yi, dy = (sh - 1) * dy, -dy
        sx, sy, ex, ey = xpos, ypos, xpos + sw, ypos + sh
        if sx < x0:
            xib += (x0 - sx) * dx; sx = x0
        if sy < y0:
            yi += (y0 - sy) * dy; sy = y0
        ex, ey = min(ex, x1 + 1), min(ey, y1 + 1)
        if ex <= sx:
            continue
        for y in range(sy, ey):
            row = gfx[yi >> 16]
            xi = xib + dx * np.arange(ex - sx)
            c = row[xi >> 16].astype(np.int64)
            m = c != 0xff
            seg = out[y, sx:ex]
            seg[m] = (prival << 12) | ((color * 256 + c[m]) & 0xfff)
            yi += dy
    return out


# ------------------------------------------------------------------ screen
def render(r, st, board='std', pal=None):
    """namcos2_state::screen_update -> RGB (H, W) uint32. `pal`: the State whose
    palette colours the picture (NS2-2: MAME's picture F+1 is state F's
    composition with state F+1's palette, as GN-2 / MS1Z-5)."""
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
