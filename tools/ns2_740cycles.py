#!/usr/bin/env python3
"""MAME's M37450 (m740) cycles per instruction, measured: MAME's 6502-family
cores make one bus access per cycle, so an instruction's cycles are the
accesses from its opcode fetch to the next instruction's
(sim/oracle/ns2_mcutrace.lua: mcu_bus.txt and mcu_pc.txt).

    tools/ns2_740cycles.py TRACE_DIR     -> per opcode (and T mode): cycle counts seen

An interrupt's entry lands in the instruction before it; the most frequent
count is the instruction's, the others are page crossings, taken branches or
interrupts.
"""
import collections, re, sys

T_MNEMOS = {'ort', 'andt', 'eort', 'adct', 'ldt', 'cmpt', 'sbct'}


def main():
    d = sys.argv[1]
    bus = [l.split() for l in open(d + '/mcu_bus.txt')]
    stats = collections.defaultdict(collections.Counter)
    names = {}
    bi = 0
    prev = None
    for line in open(d + '/mcu_pc.txt'):
        m = re.match(r'\s*([0-9A-F]+):\s+(\S+)', line)
        if not m:
            continue
        pc, mn = int(m.group(1), 16), m.group(2)
        # this instruction's opcode fetch: the next read of its PC
        start = bi
        while bi < len(bus) and not (bus[bi][0] == 'R' and int(bus[bi][1], 16) == pc):
            bi += 1
        if bi >= len(bus):
            break
        if prev is not None:
            stats[prev][bi - prev_start] += 1
        op = int(bus[bi][2], 16)
        key = (op, mn in T_MNEMOS)
        names[key] = mn
        prev, prev_start = key, bi
        bi += 1
    for key in sorted(stats):
        c = stats[key]
        top = c.most_common(4)
        print('%02x %s %-5s cycles %s' % (key[0], 'T' if key[1] else '-', names[key],
              ' '.join('%d:%d' % (k, v) for k, v in top)))


if __name__ == '__main__':
    main()
