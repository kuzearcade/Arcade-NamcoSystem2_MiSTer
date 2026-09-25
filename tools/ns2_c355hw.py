#!/usr/bin/env python3
"""The C355 as the RTL computes it (rtl/ns2_c355.sv): a per-frame pass that
condenses the list, then line by line, the rows and columns in closed form.
tools/ns2_model.py sprites_c355 (MAME's frame algorithm) is the reference:

    tools/ns2_c355hw.py SET TRACE_DIR [every]     compares the two bitmaps

MAME splits a sprite of V pixels into n rows by repeated division (a row is
the remaining height / the remaining rows): with q = V // n, rem = V % n the
first n - rem rows are q high and the last rem rows q + 1, so row r starts at
r*q + max(0, r - (n - rem)). Its zoom, (remaining << 16) / (16 * rows left),
is q * 4096 + (min(rem, rows left) * 4096) // rows left: a 16 x 16 table.
Columns likewise.
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_model as M

H, W = M.H, M.W
# the zoom table: (k * 4096) // left for k, left in 1..16 (k <= left)
ZT = [[(k * 4096) // l if l else 0 for k in range(17)] for l in range(17)]


def split(V, n, r):
    """row r of n over V pixels: (start, height, zoom << 16 / 16 per tile)"""
    q, rem = V // n, V % n
    start = r * q + max(0, r - (n - rem))
    h = q + (1 if r >= n - rem else 0)
    left = n - r
    zoom = q * 4096 + ZT[left][min(rem, left)]
    return start, h, zoom


def prepass(st):
    """the per-frame pass: one record per list entry"""
    ram = st.b['c355']
    pos = st.b['c355pos'] if 'c355pos' in st.b else np.zeros(4, np.int64)
    sext = lambda v, b: (v & ((1 << b) - 1)) - ((v & (1 << (b - 1))) << 1)
    xs, ys = sext(int(pos[1]), 9) + 0x26, sext(int(pos[0]), 9) + 0x19
    out = []
    for i in range(256):
        which = int(ram[0x1000 + i])
        t = [int(ram[((which & 0xff) << 3) + a]) for a in range(8)]
        palette = t[6]
        ce = (palette >> 8) & 0xf
        ct = [int(ram[0x1200 + (ce << 2) + a]) for a in range(4)]
        f = [int(ram[0x2000 + ((t[0] & 0x7ff) << 2) + a]) for a in range(4)]
        n_c, n_r = (f[1] >> 4) & 0xf or 16, f[1] & 0xf or 16
        hs, vs = t[4], t[5]
        rec = None
        if hs & 0x3ff and vs & 0x3ff:
            flipx, flipy, H_, V_ = bool(hs & 0x8000), bool(vs & 0x8000), hs & 0x3ff, vs & 0x3ff
            hpos, vpos = sext((t[2] - xs) & 0x7ff, 11), sext((t[3] - ys) & 0x7ff, 11)
            dx, dy = f[2] & 0x1ff, f[3] & 0x1ff
            zx = (H_ << 16) // (n_c * 16)
            dxz = ((dx & 0xff) * zx + 0x8000) >> 16
            hpos += (dxz if flipx else -dxz) * (-1 if dx & 0x100 else 1)
            zy = (V_ << 16) // (n_r * 16)
            dyz = ((dy & 0xff) * zy + 0x8000) >> 16
            vpos += (dyz if flipy else -dyz) * (-1 if dy & 0x100 else 1)
            rec = dict(pri=(palette >> 4) & 0xf, color=palette & 0xf, flipx=flipx, flipy=flipy,
                       H=H_, V=V_, nc=n_c, nr=n_r, hpos=hpos, vpos=vpos, tile=f[0], offset=t[1],
                       clip=(ct[0] - xs, ct[1] - xs, ct[2] - ys, ct[3] - ys))
        out.append(rec)
        if which & 0x100:
            break
    return out


def line(r, st, recs, y, clip, out):
    """one line, as the RTL draws it"""
    ram = st.b['c355']
    X0, X1, Y0, Y1 = clip
    for s in recs:
        if s is None:
            continue
        cx0, cx1, cy0, cy1 = max(s['clip'][0], X0), min(s['clip'][1], X1), max(s['clip'][2], Y0), min(s['clip'][3], Y1)
        if not (cy0 <= y <= cy1):
            continue
        for rr in range(s['nr']):
            ystart, th, zoomy = split(s['V'], s['nr'], rr)
            top = s['vpos'] - ystart - th if s['flipy'] else s['vpos'] + ystart
            sh = (zoomy * 16 + 0x8000) >> 16
            if not (top <= y < top + sh) or not sh:
                continue
            ddy = (16 << 16) // sh
            i = y - top
            srow = (((sh - 1 - i) if s['flipy'] else i) * ddy) >> 16
            for c in range(s['nc']):
                xstart, tw, zoomx = split(s['H'], s['nc'], c)
                left = s['hpos'] - xstart - tw if s['flipx'] else s['hpos'] + xstart
                sw = (zoomx * 16 + 0x8000) >> 16
                ti = s['tile'] + rr * s['nc'] + c
                tile = int(ram[0x4000 + ti]) if ti < 0x6100 else 0
                if tile & 0x8000 or not sw:
                    continue
                img = r.c355[(tile + s['offset']) % len(r.c355)]
                ddx = (16 << 16) // sw
                for j in range(sw):
                    x = left + j
                    if cx0 <= x <= cx1:
                        col = ((((sw - 1 - j) if s['flipx'] else j) * ddx) >> 16)
                        p = int(img[srow, col])
                        if p != 0xff:
                            out[y, x] = ((s['pri'] & 0xf) << 12) | ((s['color'] * 256 + p) & 0xfff)


def sprites(r, st, clip):
    out = np.full((H, W), 0xffff, np.int64)
    recs = prepass(st)
    for y in range(H):
        line(r, st, recs, y, clip, out)
    return out


def main():
    name, trace = sys.argv[1], sys.argv[2]
    every = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    r = M.Roms(name)
    blocks = M.read_blocks(trace)
    have = sorted(int(f[1:6]) for f in os.listdir(trace) if f.startswith('s') and f.endswith('.bin'))
    bad = 0
    for F in have[::every]:
        st = M.State(os.path.join(trace, f's{F:05d}.bin'), blocks)
        c = st.c116
        clip = (max(c[0] - 0x4a, 0), min(c[1] - 0x4b, W - 1), max(c[2] - 0x21, 0), min(c[3] - 0x22, H - 1))
        ref = M.sprites_c355(r, st, clip)
        hw = sprites(r, st, clip)
        d = int((ref != hw).sum())
        bad += d != 0
        print(f'{name} {F}: {d} pixels differ ({int((ref != 0xffff).sum())} sprite pixels)')
    print('ALL EQUAL' if not bad else f'{bad} frames differ')


if __name__ == '__main__':
    main()
