#!/usr/bin/env python3
"""Write a set's graphics regions, as the core's fetch paths see them (the
board wiring applied, NS2-1), for the RTL testbenches:

    tools/ns2_romdump.py SET [OUTDIR]     default sim/rtl/roms/SET/

tiles.bin (c123tmap), tmask.bin (c123tmap:mask), roz.bin (s2roz),
sprite.bin, c169.bin, c169mask.bin, c355.bin, clut.bin, mcu_int.bin (the C65's
or C68's internal ROM), mcu_ext.bin (its EPROM), the CPUs' ROMs, nvram.bin and
c140.bin (the voices, big-endian words): whichever the set has. ROM-derived: the output
directory is git-ignored and never committed.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
FILES = {'c123tmap': 'tiles.bin', 'c123tmap:mask': 'tmask.bin', 's2roz': 'roz.bin',
         'sprite': 'sprite.bin', 'c169roz:mask': 'c169mask.bin', 'c169roz': 'c169.bin',
         'c355spr': 'c355.bin', 'c45_road:clut': 'clut.bin',
         'mcu_int': 'mcu_int.bin', 'c65mcu:external': 'mcu_ext.bin', 'c68mcu:external': 'mcu_ext.bin',
         'maincpu': 'maincpu.bin', 'slave': 'slave.bin', 'data_rom': 'data.bin', 'audiocpu': 'audio.bin',
         'nvram': 'nvram.bin', 'c140': 'c140.bin'}


def main():
    name = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'sim/rtl/roms', name)
    os.makedirs(out, exist_ok=True)
    regions, _ = R.build(name)
    for tag, fn in R.WIRING.get(R.games()[name]['init'], {}).items():
        regions[tag] = fn(regions[tag])
    for tag, f in FILES.items():
        if tag in regions:
            open(os.path.join(out, f), 'wb').write(regions[tag])
            print(f'{name}: {f} {len(regions[tag])} bytes')


if __name__ == '__main__':
    main()
