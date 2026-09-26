#!/usr/bin/env python3
"""The board's pictures against MAME's CPUs, line by line (NS2-10).

    tools/ns2_replay.py SET TRACE RTL_DIR [--from F] [--to F]

MAME draws a picture in bands, at the POSIRQ line and at vblank, so a game
that writes the video during the frame shows in MAME's picture what the
board's raster shows a band later or earlier (NS2-2). The board's picture is
instead replayed here from MAME's own writes, as the raster meets them:
- TRACE: tools/ns2_capture.py's capture (sNNNNN.bin, blocks.txt, and
  writes.txt: every video write at its clock);
- the state captured at the start of frame F (sF-1, at F * 811008) plus the
  writes made before a line's fetch (during the line before it) gives its
  tiles, sprites, ROZ and registers; those made before its output, its
  colours;
- the model (tools/ns2_model.py) renders each distinct state once.
RTL_DIR holds the board's pictures (sim/rtl/ns2_frames PICS_DUMP:
rtlNNNNN.raw, u32 0x00RRGGBB, frame F's lines). A line that differs with no
write between its fetch and its output is an error; one with a write there
is reported apart (the board may show either).
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_model as M

FRAME, LINE, H, W = 811008, 3072, 224, 288


def read_writes(trace):
    """writes.txt -> sorted arrays (clock, addr, data, mask)"""
    t, a, d, m = [], [], [], []
    for line in open(os.path.join(trace, 'writes.txt')):
        f = line.split()
        t.append(int(f[0])); a.append(int(f[1], 16)); d.append(int(f[2], 16)); m.append(int(f[3], 16))
    o = np.argsort(np.array(t, np.int64), kind='stable')
    return (np.array(t, np.int64)[o], np.array(a, np.int64)[o], np.array(d, np.int64)[o], np.array(m, np.int64)[o])


class Live:
    """a state that the writes advance"""
    def __init__(self, st, blocks):
        self.b = {k: v.copy() for k, v in st.b.items()}
        self.blocks = [(n, a, c) for n, a, c in blocks if n in self.b]

    def apply(self, a, d, m):
        for n, a0, c in self.blocks:
            if a0 <= a < a0 + 2 * c:
                i = (a - a0) // 2
                self.b[n][i] = (int(self.b[n][i]) & ~m) | (d & m)
                return

    def state(self):
        s = M.State.__new__(M.State)
        s.b = {k: v.copy() for k, v in self.b.items()}
        pal = s.b['pal'] & 0xff
        o = np.arange(0x8000)
        plane = (o & 0x1800) >> 11
        color = ((o & 0x6000) >> 2) | (o & 0x7ff)
        s.rgb = np.zeros((0x2000, 3), np.int64)
        for p in range(3):
            sel = plane == p
            s.rgb[color[sel], p] = pal[sel]
        s.c116 = [(int(pal[0x1800 + 2 * r]) << 8) | int(pal[0x1801 + 2 * r]) for r in range(8)]
        return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set'); ap.add_argument('trace'); ap.add_argument('rtl')
    ap.add_argument('--from', dest='frm', type=int, default=1); ap.add_argument('--to', type=int, default=10 ** 9)
    ap.add_argument('--fetch', type=int, default=LINE, help='clocks before a line output that its fetch starts')
    a = ap.parse_args()
    r = M.Roms(a.set)
    blocks = M.read_blocks(a.trace)
    wt, wa, wd, wm = read_writes(a.trace)
    exact = total = 0
    for F in range(a.frm, a.to + 1):
        sp = os.path.join(a.trace, f's{F - 1:05d}.bin')
        rp = os.path.join(a.rtl, f'rtl{F:05d}.raw')
        if not (os.path.exists(sp) and os.path.exists(rp)):
            continue
        rtl = np.fromfile(rp, '<u4').reshape(H, W) & 0xffffff
        live_f = Live(M.State(sp, blocks), blocks)          # the fetch's state
        live_o = Live(M.State(sp, blocks), blocks)          # the output's (colours)
        t0 = F * FRAME
        i_f = i_o = int(np.searchsorted(wt, t0))
        cache, bad, window = {}, [], []
        for y in range(H):
            t_o = t0 + (40 + y) * LINE
            t_f = t_o - a.fetch
            while i_f < len(wt) and wt[i_f] < t_f:
                live_f.apply(int(wa[i_f]), int(wd[i_f]), int(wm[i_f])); i_f += 1
            while i_o < len(wt) and wt[i_o] < t_o:
                live_o.apply(int(wa[i_o]), int(wd[i_o]), int(wm[i_o])); i_o += 1
            key = (i_f, i_o)
            if key not in cache:
                cache.clear()
                cache[key] = M.render(r, live_f.state(), pal=live_o.state())
            line = cache[key][y]
            if (line != rtl[y]).any():
                # a write between this line's fetch and the end of its output
                (window if np.searchsorted(wt, t_o + LINE) > np.searchsorted(wt, t_f) else bad).append(y)
        total += 1
        exact += not bad and not window
        if bad or window:
            print(f'frame {F}: {len(bad)} lines differ{" (" + str(bad[0]) + "-" + str(bad[-1]) + ")" if bad else ""}'
                  f', {len(window)} with a write in their window')
        sys.stdout.flush()
    print(f'{exact} / {total} frames exact')


if __name__ == '__main__':
    main()
