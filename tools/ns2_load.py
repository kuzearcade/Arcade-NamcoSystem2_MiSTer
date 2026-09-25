#!/usr/bin/env python3
"""Q3 (docs/PLAN.md): the graphics ROM load per line of captured frames, in
64-bit SDRAM bursts, which sizes D3's bandwidth gate (MP-3's method).

Each line's fetches, in the order a line renderer makes them (left to right,
plane by plane; a burst equal to the one just fetched is not fetched again),
as 16-bit word addresses within the stream's own region:
  tiles    a tile row is 8 bytes (tile 64 bytes)
  masks    a tile's whole mask is 8 bytes (C123 mask ROM)
  roz      a ROZ tile row is 8 bytes (tile 64 bytes)
  sprites  8 source pixels of a sprite row (row 32 bytes, sprite 1024 bytes,
           obj_layout); every row a line draws is fetched whole
A line's work spreads over the whole 62.5 us line (line buffers), so
M/s = bursts / 62.5.

--mixed-masks fetches a mask only for a mixed tile: the core keeps a 2-bit
class per tile (all transparent / all opaque / mixed) in BRAM, from the mask
ROM at load time, and needs the mask ROM only for the mixed tiles.

--cache STREAM=N[,...] passes a stream through an N-entry direct-mapped cache
of bursts (index = burst number mod N, cleared per sampled frame): what the
SDRAM still sees is the misses.

    tools/ns2_load.py SET TRACE_DIR [--every K] [--cache roz=512,masks=512] [--mixed-masks]
    tools/ns2_load.py SET TRACE_DIR --dump PREFIX --frames F ... [--cache ...]

--dump writes each stream's SDRAM fetches (after the caches) for the given
frames to PREFIX_{roz,tiles,masks,sprites}.txt, which sim/rtl/sdram_probe
replays (REPLAY=...).
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_model as M

LINE_US = 384 / 6.144
STREAMS = ('roz', 'tiles', 'masks', 'sprites')


def _dedup(seq):
    out = []
    for w in seq:
        if not out or out[-1] != w:
            out.append(int(w))
    return out


def line_streams(st):
    """{stream: [per-line list of burst word addresses]}"""
    ctl = st.b['tctl']; vram = st.b['tmap']
    flip = bool(ctl[1] & 0x8000)
    ys, xs = np.mgrid[0:M.H, 0:M.W]
    lay = []
    for i in range(6):
        if int(ctl[0x10 + i]) & 8:
            continue
        if i < 4:
            sx, sy = int(ctl[4 * i + 1]) & 0x1ff, int(ctl[4 * i + 3]) & 0x1ff
            tx = (xs + sx + 44 + (4, 2, 1, 0)[i]) % 512; ty = (ys + sy + 24) % 512
            if flip:
                tx, ty = 511 - tx, 511 - ty
            code = vram[i * 0x1000 + (ty // 8) * 64 + tx // 8]
        else:
            tx, ty = (M.W - 1 - xs, M.H - 1 - ys) if flip else (xs, ys)
            code = vram[(0x4008, 0x4408)[i - 4] + (ty // 8) * 36 + tx // 8]
        lay.append((M.tile_cb_std(code) * 32 + (ty % 8) * 4, code * 4))
    roz = inside = None
    if 'roz' in st.b:
        c = [int(v) for v in st.b['rozctl']]
        s16 = lambda v: v - 0x10000 if v & 0x8000 else v
        incxx, incxy, incyx, incyy = (s16(c[k]) for k in range(4))
        size, wrap = 2048, True
        if c[7] in (0x4488, 0x44cc):
            wrap = False
        elif c[7] == 0x44ee:
            wrap, size = False, 256
        startx = ((s16(c[4]) << 4) + 38 * incxx) << 8
        starty = ((s16(c[5]) << 4) + 38 * incxy) << 8
        incxx, incxy, incyx, incyy = (v << 8 for v in (incxx, incxy, incyx, incyy))
        xp = ((startx + xs * incxx + ys * incyx) & 0xffffffff) >> 16
        yp = ((starty + xs * incxy + ys * incyy) & 0xffffffff) >> 16
        if wrap:
            xp &= size - 1; yp &= size - 1
            inside = np.ones_like(xp, bool)
        else:
            inside = (xp <= size) & (yp < size)
            xp = np.minimum(xp, 2047); yp = np.minimum(yp, 2047)
        roz = st.b['roz'][(yp // 8) * 256 + xp // 8] * 32 + (yp % 8) * 4
    spr = []
    if 'spr' in st.b:
        sp = st.b['spr']; base = (int(st.b['gfxctl'][0]) & 0xf) * 512
        for loop in range(128):
            w0, w1, w2, w3 = (int(sp[base + loop * 4 + k]) for k in range(4))
            sizey = ((w0 >> 10) & 0x3f) + 1; is32 = bool(w0 & 0x200)
            sizex = (w3 >> 10) & 0x3f
            if not is32:
                sizex >>= 1
            if not ((sizey - 1) and sizex):
                continue
            gw = 32 if is32 else 16
            sw = ((((sizex << 16) // gw) * gw + 0x8000) >> 16)
            sh = ((((sizey << 16) // gw) * gw + 0x8000) >> 16)
            if not (sw and sh):
                continue
            ypos = (0x1ff - (w0 & 0x1ff)) - 0x50 + 0x02
            xpos = (w2 & 0x7ff) - 0x50 + 0x07
            if xpos + sw <= 0 or xpos >= M.W:
                continue
            spr.append(((w1 >> 2) & 0xfff, ypos, sh, gw, (16 if w1 & 1 else 0), (16 if w1 & 2 else 0)))
    out = {k: [] for k in STREAMS}
    for y in range(M.H):
        out['tiles'].append(_dedup(w for t, _ in lay for w in t[y]))
        out['masks'].append(_dedup(w for _, m in lay for w in m[y]))
        out['roz'].append(_dedup(roz[y][inside[y]]) if roz is not None else [])
        s = []
        for n, yp, sh, gw, qx, qy in spr:
            if yp <= y < yp + sh:
                row = (y - yp) * gw // sh + qy
                s += [n * 512 + row * 16 + (qx // 8 + k) * 4 for k in range(gw // 8)]
        out['sprites'].append(s)
    return out


class Cache:
    def __init__(self, n):
        self.n, self.tag = n, np.full(n, -1, np.int64)

    def misses(self, seq):
        out = []
        for w in seq:
            b = w >> 2
            i = b % self.n
            if self.tag[i] != b:
                self.tag[i] = b
                out.append(w)
        return out


def mask_classes(name):
    """per tile: 0 all transparent, 1 all opaque, 2 mixed"""
    import ns2_romdata as R
    regions, _ = R.build(name)
    m = np.unpackbits(np.frombuffer(regions['c123tmap:mask'], np.uint8)).reshape(-1, 64)
    return np.where(m.all(1), 1, np.where(~m.any(1), 0, 2))


def through(streams, caches):
    """the SDRAM fetches of each line after the caches (fresh per frame)"""
    out = {}
    for k, lines in streams.items():
        if k in caches:
            c = Cache(caches[k])
            out[k] = [c.misses(l) for l in lines]
        else:
            out[k] = lines
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set'); ap.add_argument('trace'); ap.add_argument('--every', type=int, default=10)
    ap.add_argument('--cache', default='')
    ap.add_argument('--mixed-masks', action='store_true')
    ap.add_argument('--dump'); ap.add_argument('--frames', type=int, nargs='*')
    a = ap.parse_args()
    caches = {k: int(v) for k, v in (c.split('=') for c in a.cache.split(',') if c)}
    blocks = M.read_blocks(a.trace)
    have = sorted(int(f[1:6]) for f in os.listdir(a.trace) if f.startswith('s') and f.endswith('.bin'))
    frames = a.frames or have[::a.every]
    cls = mask_classes(a.set) if a.mixed_masks else None
    files = {k: open(f'{a.dump}_{k}.txt', 'w') for k in STREAMS} if a.dump else None
    worst = {}
    for F in frames:
        s = line_streams(M.State(os.path.join(a.trace, f's{F:05d}.bin'), blocks))
        if cls is not None:
            s['masks'] = [[w for w in l if cls[(w >> 2) % len(cls)] == 2] for l in s['masks']]
        s = through(s, caches)
        if files:
            for k in STREAMS:
                files[k].write(''.join(f'{w & 0x3fffff:06x}\n' for l in s[k] for w in l))
        per = {k: np.array([len(l) for l in s[k]]) for k in STREAMS}
        per['total'] = sum(per[k] for k in STREAMS)
        for k, v in per.items():
            if v.max() > worst.get(k, (-1, 0))[0]:
                worst[k] = (int(v.max()), F)
    if files:
        for f in files.values():
            f.close()
    tag = (f' (caches {a.cache})' if a.cache else '') + (' (mixed masks)' if a.mixed_masks else '')
    for k, (v, F) in worst.items():
        print(f'{a.set}{tag} {k:8s} worst line {v:4d} = {v / LINE_US:5.2f} M bursts/s  (frame {F})')


if __name__ == '__main__':
    main()
