#!/usr/bin/env python3
"""High scores and cheats in the .mra files (NS2-30), for tools/ns2_mra.py.

Both act on the master 68000's memory through ns2_board's back door, which
reaches its work RAM (100000-10ffff; on Suzuka 8 Hours and Lucky & Wild
through its cache in the SDRAM, NS2-33) and the C123's RAM (400000-41ffff).

High scores (MAME's plugins/hiscore/hiscore.dat): <rom index="3"> is
hiscore.v's config, a 16-byte header then a record a hiscore.dat line
(CFG_LENGTHWIDTH 2: 4 bytes address, 2 bytes length, start and end check
bytes). The dump is saved after the EEPROM in the one .nvm: <nvram index="4">
grows from 8192 bytes by the dump's length (NamcoS2.sv: the dump at 0x2000).

Cheats (Pugsy's MAME cheat database): <rom index="5"> is rtl/cheats.sv's
table, SLOTS fixed slots (NamcoS2.sv's OSD, same order) of 2 + 3 x 6 bytes:
a count, a pad, then up to three actions {3 bytes address, kind, 2 bytes
value} (kind 0 byte, 1 word, 2 masked byte: value {mask, byte}). A slot takes
the set's first cheat named in its ALIASES, if every action of it is a
plain or masked write the back door reaches; parameterised cheats are left
out.
"""
import os
import re

HISCORE_DAT = os.path.expanduser('~/mame/plugins/hiscore/hiscore.dat')
CHEAT_DIR = os.path.expanduser('~/Downloads/cheat0279/cheat')
EEPROM_BYTES = 8192

# hiscore.v's timings (cycles of the 49.152 MHz clk_sys): START_WAIT ~10 s, past
# the boards' work RAM tests (a restore during one fails it), then the start
# and end bytes checked every CHECK_WAIT
HDR = [0x1D, 0x4C, 0x00, 0x00,  # START_WAIT
       0xFF, 0xFF,              # CHECK_WAIT: 1.3 ms (NS2-36: at 0xff, 5 us, the
                                #   checks' pauses held Lucky & Wild (Japan) on its
                                #   notice until its table appeared, which it never did)
       0x00, 0x02,              # CHECK_HOLD
       0x00, 0x02,              # WRITE_HOLD
       0x00, 0x01,              # WRITE_REPEATCOUNT
       0x00, 0xFF,              # WRITE_REPEATWAIT
       0x10,                    # ACCESS_PAUSEPAD: 16 clocks; ns2_board's back door is
                                #   ready 8 clocks after the request (2 read and wrote
                                #   before it: the checks failed, the writes were lost)
       0x00]                    # CHANGEMASK bytes

SLOTS = ['Infinite Time', 'Infinite Credits', 'P1 Invincibility', 'P2 Invincibility',
         'P1 Infinite Lives', 'P2 Infinite Lives', 'P1 Infinite Energy', 'P2 Infinite Energy',
         'Maximum Speed', 'P1 Infinite Weapons']
ALIASES = {
    'Infinite Time': ['Infinite Time'],
    'Infinite Credits': ['Infinite Credits', 'P1 Infinite Credits'],
    'P1 Invincibility': ['P1 Invincibility', 'Invincibility'],
    'P2 Invincibility': ['P2 Invincibility'],
    'P1 Infinite Lives': ['P1 Infinite Lives', 'Infinite Lives'],
    'P2 Infinite Lives': ['P2 Infinite Lives'],
    'P1 Infinite Energy': ['P1 Infinite Energy', 'Infinite Energy'],
    'P2 Infinite Energy': ['P2 Infinite Energy'],
    'Maximum Speed': ['Always drive at Maximum Speed'],
    'P1 Infinite Weapons': ['P1 Infinite Missiles', 'Infinite Missiles', 'P1 Infinite Bombs', 'Infinite Bombs',
                            'Infinite Grenades', 'P1 Infinite Shots', 'Infinite Shots'],
}
MAXACT = 3
ACT = re.compile(r'<action(?:\s+condition="[^"]*")?\s*>\s*(.*?)\s*</action>', re.S)
PLAIN = re.compile(r'maincpu\.p([bw])@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)$')
MASKED = re.compile(r'maincpu\.pb@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)\|\(maincpu\.pb@\1 BAND ~([0-9A-Fa-f]+)\)$')


def reachable(a):
    return 0x100000 <= a < 0x110000 or 0x400000 <= a < 0x420000


def load_dat(path=HISCORE_DAT):
    """hiscore.dat: set -> its @ lines (consecutive labels share a block)"""
    out, pending, cur = {}, [], []
    for ln in open(path, encoding='utf-8', errors='replace'):
        s = ln.strip()
        if not s or s.startswith(';'):
            continue
        if s.startswith('@'):
            if pending:
                cur, pending = pending, []
            for c in cur:
                out.setdefault(c, []).append(s)
        elif s.endswith(':'):
            if cur:
                cur = []
            pending += [x.strip() for x in s[:-1].split(',') if x.strip()]
    return out


_DAT = None


def hiscore(name):
    """(the index-3 rows, the dump's length), or None"""
    global _DAT
    if _DAT is None:
        _DAT = load_dat() if os.path.exists(HISCORE_DAT) else {}
    if name not in _DAT:
        return None
    rows, total = [HDR], 0
    for ln in _DAT[name]:
        f = ln.split(':', 1)[1].split(',')
        if len(f) < 6 or f[0].strip() != 'maincpu' or f[1].strip() != 'program':
            return None
        a, n, start, end = int(f[2], 16), int(f[3], 16), int(f[4], 16), int(f[5], 16)
        if not (reachable(a) and reachable(a + n - 1)):
            return None
        rows.append([(a >> 24) & 0xff, (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff, (n >> 8) & 0xff, n & 0xff, start, end])
        total += n
    return rows, total


def _actions(body):
    acts = []
    for a in ACT.findall(body):
        m = PLAIN.match(a)
        if m:
            sz, addr, v = m.groups()
            acts.append((int(addr, 16), 1 if sz == 'w' else 0, int(v, 16)))
            continue
        m = MASKED.match(a)
        if m:
            addr, v, mask = m.groups()
            acts.append((int(addr, 16), 2, (int(mask, 16) << 8) | int(v, 16)))
            continue
        return None                                   # temp variables, other CPUs, ROM patches
    if not acts or len(acts) > MAXACT or not all(reachable(a + (k == 1)) and reachable(a) for a, k, _ in acts):
        return None
    return acts


def cheats(name):
    """(the index-5 rows, the slots provided), or None"""
    p = os.path.join(CHEAT_DIR, f'{name}.xml')
    if not os.path.exists(p):
        return None
    t = open(p, encoding='utf-8', errors='replace').read()
    found = {}
    for m in re.finditer(r'<cheat desc="([^"]*)"\s*>(.*?)</cheat>', t, re.S):
        d, body = m.group(1).strip(), m.group(2)
        if '<parameter' in body:
            continue
        acts = _actions(body)
        if acts and d not in found:
            found[d] = acts
    rows, provided = [], []
    for slot in SLOTS:
        acts = next((found[d] for d in ALIASES[slot] if d in found), [])
        if acts:
            provided.append(slot)
        rec = [len(acts), 0]
        for i in range(MAXACT):
            if i < len(acts):
                a, k, v = acts[i]
                rec += [(a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff, k, (v >> 8) & 0xff, v & 0xff]
            else:
                rec += [0] * 6
        rows.append(rec)
    return (rows, provided) if provided else None


def fmt(rows):
    return '\n'.join('      ' + ' '.join(f'{b:02X}' for b in r) for r in rows)


def blocks(name, served):
    """the .mra lines for a set (served: its bitstream has the back door: every
    one now), and the NVRAM's size"""
    out, size = [], EEPROM_BYTES
    h = hiscore(name) if served else None
    if h:
        rows, total = h
        out += [f'  <!-- High scores: hiscore.dat\'s {name} (tools/ns2_extras.py); the dump follows',
                f'       the EEPROM in the .nvm, {total} bytes -->',
                '  <rom index="3" md5="none">', '    <part>', fmt(rows), '    </part>', '  </rom>', '']
        size += total + (total & 1)                   # whole words (hps_io is 16 bits wide)
    c = cheats(name) if served else None
    if c:
        rows, provided = c
        out += [f'  <!-- Cheats (Pugsy\'s database, tools/ns2_extras.py): {", ".join(provided)} -->',
                '  <rom index="5" md5="none">', '    <part>', fmt(rows), '    </part>', '  </rom>', '']
    return out, size
