#!/usr/bin/env python3
# the core's YM write FIFO (rtl/ns2_ym_fifo.sv) on a write log: each write's
# time as it leaves the FIFO for jt51 (data writes at least 64 YM cycles
# apart, an address write as soon as it is at the head)
import sys
fy = 3579545.0
w = [l.split() for l in open(sys.argv[1])]
out = open(sys.argv[2], 'w'); last = -1e9; t_free = 0.0; peak = 0; q = 0
for t, a, d in w:
    t = float(t)
    leave = max(t, t_free)
    if a == '1':
        leave = max(leave, last + 64 / fy)
        last = leave
    t_free = leave + 1 / 49152000 * 2
    out.write(f'{leave:.9f} {a} {d}\n')
