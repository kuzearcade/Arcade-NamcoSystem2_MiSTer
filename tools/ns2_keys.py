#!/usr/bin/env python3
"""The key custom's table per set (rtl/ns2_key.sv), from MAME:
namcos2_m.cpp namcos2_68k_key_r (transcribed below; any offset missing
returns the random value) and namcos2.cpp's init functions (the game type
each set's init assigns).

    tools/ns2_keys.py [SET ...]      prints SET: mode, table (offsets 0-7)
    ns2_keys.table(SET) -> (mode, [(valid, value)] * 8)

mode 1 is Marvel Land's handshake, mode 2 Rolling Thunder 2's.
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

# namcos2_68k_key_r: gametype -> {offset: value}
KEYS = {
    'NAMCOS2_ORDYNE': {2: 0x1001, 3: 0x1, 4: 0x110, 5: 0x10, 6: 0xb0, 7: 0xb0},
    'NAMCOS2_STEEL_GUNNER_2': {4: 0x15a},
    'NAMCOS2_MIRAI_NINJA': {7: 0xb1},
    'NAMCOS2_PHELIOS': {0: 0xf0, 1: 0xff0, 2: 0xb2, 3: 0xb2, 4: 0xf, 5: 0xf00f, 7: 0xb2},
    'NAMCOS2_DIRT_FOX_JP': {1: 0xb4},
    'NAMCOS2_FINEST_HOUR': {7: 0xbc},
    'NAMCOS2_BURNING_FORCE': {1: 0xbd},
    'NAMCOS2_MARVEL_LAND': {0: 0x10, 1: 0x110, 4: 0xbe, 6: 0x1001},    # 7: the handshake
    'NAMCOS2_DRAGON_SABER': {2: 0xc0},
    'NAMCOS2_ROLLING_THUNDER_2': {2: 0},                                # 4, 7: the handshake
    'NAMCOS2_COSMO_GANG': {3: 0x14a},
    'NAMCOS2_SUPER_WSTADIUM': {4: 0x142},
    'NAMCOS2_SUPER_WSTADIUM_92': {3: 0x14b},
    'NAMCOS2_SUPER_WSTADIUM_92T': {3: 0x14c},
    'NAMCOS2_SUPER_WSTADIUM_93': {3: 0x14e},
    'NAMCOS2_SUZUKA_8_HOURS_2': {3: 0x14d, 2: 0},
    'NAMCOS2_GOLLY_GHOST': {0: 2, 1: 2, 2: 0, 4: 0x143},
    'NAMCOS2_BUBBLE_TROUBLE': {0: 2, 1: 2, 2: 0, 4: 0x141},
}
MODES = {'NAMCOS2_MARVEL_LAND': 1, 'NAMCOS2_ROLLING_THUNDER_2': 2}


def gametypes(src=R.MAME_SRC):
    """init function name -> NAMCOS2_ game type"""
    text = open(os.path.join(os.path.dirname(src), 'namcos2.cpp')).read()
    out = {}
    for m in re.finditer(r'void \w+::(init_\w+)\(\)\s*\{(.*?)\n\}', text, re.S):
        g = re.search(r'm_gametype = (NAMCOS2_\w+);', m.group(2))
        if g:
            out[m.group(1)] = g.group(1)
    return out


def table(name, gm=None, gt=None):
    gm = gm or R.games()
    gt = gt or gametypes()
    t = gt.get(gm[name]['init'])
    keys = KEYS.get(t, {})
    return MODES.get(t, 0), [(k in keys, keys.get(k, 0)) for k in range(8)]


def main():
    gm, gt = R.games(), gametypes()
    if sys.argv[1:2] == ['--tb']:
        # the testbenches' KEY: "mode valid0 value0 ... valid7 value7"
        mode, tab = table(sys.argv[2], gm, gt)
        print(mode, ' '.join(f'{int(ok)} {v:x}' for ok, v in tab))
        return
    for name in sys.argv[1:] or sorted(gm):
        mode, tab = table(name, gm, gt)
        print(f"{name}: {gt.get(gm[name]['init'], '?')} mode {mode} " +
              ' '.join(f'{k}:{v:04x}' if ok else f'{k}:rng' for k, (ok, v) in enumerate(tab)))


if __name__ == '__main__':
    main()
