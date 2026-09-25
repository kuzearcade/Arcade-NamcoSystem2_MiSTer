#!/usr/bin/env python3
"""M1's flip frames (NS2-5): the games set the C123's flip (control word 1,
bit 15) from their service menus, so attract and play almost never show it.
This forces the bit into a capture's states (and every band's registers:
the bit shares plane 0's x scroll, which the games rewrite) and writes the
model's pictures, which the RTL testbench compares against (FLIP=1 REF=dir).
The model's flip was checked against MAME on sws93's flipped frames.

    tools/ns2_flipref.py SET TRACE_DIR OUTDIR first last every
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_model as M
import ns2_romdata as R


def flip(st):
    st.b['tctl'] = st.b['tctl'].copy()
    st.b['tctl'][1] |= 0x8000
    return st


def main():
    name, trace, out = sys.argv[1:4]
    first, last, every = (int(v) for v in sys.argv[4:7])
    os.makedirs(out, exist_ok=True)
    r = M.Roms(name)
    blocks = M.read_blocks(trace)
    regs, vram = M.read_regs(trace), M.read_vram(trace)
    orig = M.apply_writes
    M.apply_writes = lambda st, b, w: flip(orig(st, b, w))
    for F in range(first, last + 1, every):
        p = lambda k: os.path.join(trace, f's{k:05d}.bin')
        if not (os.path.exists(p(F)) and os.path.exists(p(F + 1))):
            continue
        st, pal = flip(M.State(p(F), blocks)), M.State(p(F + 1), blocks)
        if R.games()[name]['config'] in M.BUFFERED_C355 and os.path.exists(p(F - 1)):
            sp = M.State(p(F - 1), blocks)
            for k in ('c355', 'c355pos'):
                st.b[k] = sp.b[k]
        if regs.get(F) and os.path.exists(p(F - 1)):
            pic = M.render_banded(r, flip(M.State(p(F - 1), blocks)), st, pal, regs[F], blocks,
                                  R.games()[name]['init'] in M.BEFORE_POSIRQ, vram.get(F))
        else:
            pic = M.render(r, st, pal=pal)
        pic.astype('<u4').tofile(os.path.join(out, f'p{F + 1:05d}.raw'))
    print(name, 'flipped references written to', out)


if __name__ == '__main__':
    main()
