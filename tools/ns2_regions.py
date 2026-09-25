#!/usr/bin/env python3
"""Prove tools/ns2_romdata.py's rebuild of every region equal to MAME's own.

For each set, MAME runs `sim/oracle/ns2_regions.lua`, which dumps every region
it loaded, and each dump is compared byte for byte with the rebuild
(MS1-49: a byte order is proven against MAME's memory, never assumed).

    tools/ns2_regions.py [set ...]        all sets by default
"""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MAME = os.path.expanduser('~/mame/mame')


def mame_regions(name, out):
    subprocess.run([MAME, name, '-rompath', os.path.abspath(os.path.join(ROOT, 'mame_roms')),
                    '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
                    '-autoboot_script', os.path.join(ROOT, 'sim/oracle/ns2_regions.lua')],
                   cwd=out, env=dict(os.environ, MP_OUT=out), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    # MAME runs in the temporary directory: its nvram/ and cfg/ (ROM-derived) never touch the repo
    return {f[:-4]: open(os.path.join(out, f), 'rb').read() for f in os.listdir(out) if f.endswith('.bin')}


def main():
    sets, gm = R.parse(), R.games()
    bad = 0
    for name in sys.argv[1:] or sorted(sets):
        regions, _ = R.build(name, sets, gm)
        for tag, fn in R.WIRING.get(gm[name]['init'], {}).items():
            regions[tag] = fn(regions[tag])
        with tempfile.TemporaryDirectory() as d:
            mame = mame_regions(name, d)
        if not mame:
            print(f'{name}: MAME produced no dump (does the set run?)'); bad += 1; continue
        res = []
        for tag, data in regions.items():
            key = 'c65mcu_mcu' if tag == 'mcu_int' and 'c65mcu_mcu' in mame else \
                  'c68mcu_mcu' if tag == 'mcu_int' else tag.replace(':', '_')
            ref = mame.get(key)
            if ref is None:
                res.append(f'{tag}: not in MAME'); bad += 1; continue
            if ref != data:
                n = sum(a != b for a, b in zip(ref, data)) + abs(len(ref) - len(data))
                swapped = len(ref) == len(data) and ref == bytes(b for i in range(0, len(data), 2) for b in (data[i + 1], data[i]))
                res.append(f'{tag}: {n} bytes differ' + (' (byte-swapped words)' if swapped else '')); bad += 1
        extra = set(mame) - {('c65mcu_mcu' if t == 'mcu_int' else t.replace(':', '_')) for t in regions} - {'plds', 'unknown', 'c68mcu_mcu'}
        print(f'{name}: ' + ('; '.join(res) if res else f'{len(regions)} regions identical') +
              (f'  (MAME also has {sorted(extra)})' if extra else ''))
    print('ALL IDENTICAL' if not bad else f'{bad} problems')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
