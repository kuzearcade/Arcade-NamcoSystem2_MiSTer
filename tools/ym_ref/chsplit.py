#!/usr/bin/env python3
# a YM2151 write log cut to one channel: the global registers kept, every
# other channel's (and its operators', and its key-on writes) dropped
import sys
def chan(reg, d):
    if reg == 0x08: return d & 7
    if 0x20 <= reg <= 0x3f: return reg & 7
    if reg >= 0x40: return reg & 7
    return None          # global: test, noise, timers, LFO, CT
src, ch, dst, tmax = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
out = open(dst, 'w'); reg = 0; pend = None
for l in open(src):
    t, a, d = l.split(); a = int(a); d = int(d)
    if float(t) > tmax: break
    if a == 0: reg = d; pend = l; continue
    c = chan(reg, d)
    if c is None or c == ch:
        out.write(pend if pend else f'{t} 0 {reg}\n'); out.write(l)
    pend = None
