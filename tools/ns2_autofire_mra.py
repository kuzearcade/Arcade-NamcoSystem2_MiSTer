#!/usr/bin/env python3
"""Mirror releases/ into autofire_releases/ with the OSD's Autofire options shown.

NamcoS2.sv hides "Autofire" and "Autofire rate" (CONF_STR h1) unless the
loaded .mra's configuration block (image 0x00D6000, tools/ns2_romdata.py's
config_block) has byte 38 bit 0 set. The .mra files in releases/ never set
it; this writes a second tree, the same layout (the parents at the top,
`_alternatives/_<Parent>/` below), the same file names and <name>s, with
that bit set and nothing else changed (the ROM parts, DIPs, buttons, high
score and cheat tables byte for byte).

The flag is in the ROM download's configuration, not in <switches>, so a
saved config/dips/<name>.dip does not override it.

autofire_releases/ is git-ignored, a derived tree: re-run this whenever
releases/ changes (tools/ns2_mra.py, or a hand edit):

    python3 tools/ns2_autofire_mra.py           # rebuilds autofire_releases/
    python3 tools/ns2_autofire_mra.py --check   # reports what is stale

The output directory is emptied first, so a set removed from releases/
goes from here too.
"""
import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'releases')
DST = os.path.join(ROOT, 'autofire_releases')
UNLOCK_BYTE, UNLOCK_BIT = 38, 0x01

# the config block's part: its comment, then one <part> of 0x30 hex bytes
CFG = re.compile(r'(<!-- config: 0x30 bytes at image 0x00d6000 -->\s*<part>)([0-9A-Fa-f ]+)(</part>)')


def unlocked(text, path):
    m = CFG.search(text)
    if not m:
        sys.exit('%s: no configuration block' % path)
    b = [int(x, 16) for x in m.group(2).split()]
    if len(b) != 0x30 or b[0:2] != [0x4E, 0x32]:
        sys.exit('%s: the configuration block is not 48 bytes starting N2' % path)
    b[UNLOCK_BYTE] |= UNLOCK_BIT
    return text[:m.start(2)] + ' '.join('%02X' % x for x in b) + text[m.end(2):]


def mras():
    for d, _, files in os.walk(SRC):
        for f in sorted(files):
            if f.endswith('.mra'):
                p = os.path.join(d, f)
                yield p, os.path.relpath(p, SRC)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--check', action='store_true', help='only report what would change')
    a = ap.parse_args()
    want = {rel: unlocked(open(p, encoding='utf-8').read(), p) for p, rel in mras()}
    if a.check:
        stale = 0
        for rel, text in sorted(want.items()):
            q = os.path.join(DST, rel)
            if not os.path.exists(q) or open(q, encoding='utf-8').read() != text:
                print('stale: %s' % rel); stale += 1
        have = {os.path.relpath(os.path.join(d, f), DST) for d, _, fs in os.walk(DST) for f in fs} if os.path.isdir(DST) else set()
        for rel in sorted(have - set(want)):
            print('extra: %s' % rel); stale += 1
        print('%d of %d up to date' % (len(want) - stale, len(want)) if stale else 'all %d up to date' % len(want))
        return 1 if stale else 0
    if os.path.isdir(DST):
        shutil.rmtree(DST)
    for rel, text in sorted(want.items()):
        q = os.path.join(DST, rel)
        os.makedirs(os.path.dirname(q), exist_ok=True)
        with open(q, 'w', encoding='utf-8') as f:
            f.write(text)
    print('wrote %d .mra files to %s' % (len(want), os.path.relpath(DST, ROOT)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
