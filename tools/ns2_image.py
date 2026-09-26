#!/usr/bin/env python3
"""A set's download image, as the .mra builds it (tools/ns2_romdata.py
LAYOUT), for the M3 harness (sim/rtl/ns2_hw):

    tools/ns2_image.py SET [OUT]      default sim/rtl/roms/SET/image.bin

ROM-derived: the output directory is git-ignored and never committed.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

if __name__ == '__main__':
    name = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'sim/rtl/roms', name, 'image.bin')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    _, img = R.build(name)
    open(out, 'wb').write(img)
    print(f'{name}: {out} {len(img)} bytes')
