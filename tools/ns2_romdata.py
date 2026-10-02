#!/usr/bin/env python3
"""The one ROM table of Arcade-NamcoSystem2_MiSTer (docs/PLAN.md Appendix D).

Built mechanically from MAME's driver, not transcribed: ROM_START blocks of
`namco/namcos2.cpp` are parsed (the driver's own NAMCOS2_*_LOAD_* macros
expanded from their #defines), each set's regions are rebuilt from the zips
exactly as MAME loads them (interleaves, ROM_RELOAD mirrors, erase fills),
and `tools/ns2_regions.py` proves every region equal to MAME's own copy
(dumped through Lua) before anything else uses it (MS1-49's lesson).

One image per set, ioctl index 0 (the layout below, the same for every
set; regions a set lacks are filled as MAME fills them):
"""
import os, re, sys, zipfile, zlib

MAME_SRC = os.path.expanduser('~/mame/src/mame/namco/namcos2.cpp')
ROMS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'mame_roms')

# region tag -> (image offset, size in the image). Sizes are the largest any
# set uses; a smaller region is padded with its erase value.
LAYOUT = [
    ('maincpu',          0x0000000, 0x040000),
    ('slave',            0x0040000, 0x040000),
    ('audiocpu',         0x0080000, 0x040000),
    ('mcu_ext',          0x00C0000, 0x008000),   # c65mcu:external / c68mcu:external
    ('mcu_int',          0x00C8000, 0x008000),   # the device zip: sys2mcpu.bin (8 KB) or c68.bin (32 KB)
    ('c45_road:clut',    0x00D0000, 0x000100),
    ('nvram',            0x00D1000, 0x002000),   # MAME's default .nv, where the set has one
    ('zoomlut',          0x00D4000, 0x002000),
    ('config',           0x00D6000, 0x000030),   # the core's per-set configuration (config_block)
    ('data_rom',         0x0100000, 0x200000),
    ('c140',             0x0300000, 0x200000),
    ('c123tmap:mask',    0x0500000, 0x080000),
    ('c169roz:mask',     0x0580000, 0x080000),
    ('c123tmap',         0x0600000, 0x400000),
    ('sprite',           0x0A00000, 0x400000),   # 'sprite' or 'c355spr'
    ('roz',              0x0E00000, 0x400000),   # 's2roz' or 'c169roz'
]
TOTAL = 0x1200000
ALIASES = {'c65mcu:external': 'mcu_ext', 'c68mcu:external': 'mcu_ext',
           'c355spr': 'sprite', 's2roz': 'roz', 'c169roz': 'roz'}
MIRRORED = {'c123tmap', 'sprite', 'c355spr', 's2roz', 'c169roz'}   # graphics: codes wrap (build)
IGNORED = {'plds', 'unknown'}   # PAL dumps; finalap3a's 'unknown' ROM, which MAME never reads
DEVICE_ROMS = {   # the I/O MCU's internal ROM, from MAME's device zips
    'c65': ('namcoc65.zip', 'sys2mcpu.bin', 0x2000, 0xa342a97e),
    'c68': ('namcoc68.zip', 'c68.bin', 0x8000, 0xca64550a),
}


def _defines(src):
    """The driver's multi-line ROM macros: name -> (params, body lines)."""
    out = {}
    for m in re.finditer(r'#define\s+(NAMCOS2_\w+)\(([^)]*)\)\\\n((?:.*\\\n)*.*)', src):
        params = [p.strip() for p in m.group(2).split(',')]
        body = [l.rstrip('\\').strip() for l in m.group(3).split('\n')]
        out[m.group(1)] = (params, [b for b in body if b])
    return out


def _num(expr):
    return eval(expr, {'__builtins__': {}})   # hex literals and + only


def _args(s):
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch == ',' and depth == 0:
            parts.append(cur.strip()); cur = ''
            continue
        depth += ch == '('
        depth -= ch == ')'
        cur += ch
    parts.append(cur.strip())
    return parts


def parse(src_path=MAME_SRC):
    """setname -> list of regions {tag, size, erase, loads[{file, crc, offset, size, skip, width, nodump}]}"""
    src = open(src_path).read()
    macros = _defines(src)
    sets = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', src, re.S):
        name, body = m.group(1), m.group(2)
        lines = []
        for raw in body.split('\n'):
            line = re.sub(r'/\*.*?\*/|//.*', '', raw).strip()
            if not line:
                continue
            mm = re.match(r'(NAMCOS2_\w+)\((.*)\)\s*$', line)
            if mm and mm.group(1) in macros:
                params, mbody = macros[mm.group(1)]
                vals = _args(mm.group(2))
                for bl in mbody:
                    for p, v in zip(params, vals):
                        bl = re.sub(r'\b%s\b' % p, v, bl)
                    lines.append(bl)
            else:
                lines.append(line)
        regions, cur, last = [], None, None
        for line in lines:
            mm = re.match(r'(ROM_\w+)\((.*)\)\s*$', line)
            if not mm:
                continue
            op, a = mm.group(1), _args(mm.group(2))
            if op in ('ROM_REGION', 'ROM_REGION16_BE', 'ROM_REGION16_LE', 'ROM_REGION32_BE'):
                flags = a[2] if len(a) > 2 else '0'
                cur = dict(tag=a[1].strip('"'), size=_num(a[0]),
                           erase=0xFF if 'ERASEFF' in flags else 0x00, loads=[])
                regions.append(cur)
            elif op in ('ROM_LOAD', 'ROM_LOAD16_BYTE', 'ROM_LOAD32_BYTE'):
                width = {'ROM_LOAD': 1, 'ROM_LOAD16_BYTE': 2, 'ROM_LOAD32_BYTE': 4}[op]
                crc = re.search(r'CRC\((\w+)\)', a[3])
                last = dict(file=a[0].strip('"'), offset=_num(a[1]), size=_num(a[2]), width=width,
                            crc=int(crc.group(1), 16) if crc else None, nodump='NO_DUMP' in a[3])
                cur['loads'].append(last)
            elif op == 'ROM_RELOAD':
                cur['loads'].append(dict(last, offset=_num(a[0]), size=_num(a[1])))
        sets[name] = regions
    return sets


def games(src_path=MAME_SRC):
    """setname -> dict(parent, config, state, desc, year, rotation) from the GAME lines."""
    src = open(src_path).read()
    out = {}
    for m in re.finditer(r'^GAMEL?\(\s*(\d+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(ROT\d+),\s*"([^"]*)",\s*"([^"]*)"', src, re.M):
        year, name, parent, config, inputs, state, init, rot, manu, desc = m.groups()
        out[name] = dict(year=year, parent=None if parent == '0' else parent, config=config, inputs=inputs,
                         state=state, init=init, rotation=rot, manufacturer=manu, desc=desc)
    return out


class Files:
    """ROM files by CRC across a set's zip chain (set, parent, device zips)."""
    def __init__(self, zips):
        self.by_crc, self.by_name = {}, {}
        for z in zips:
            p = os.path.join(ROMS, z)
            if not os.path.exists(p):
                continue
            with zipfile.ZipFile(p) as zf:
                for info in zf.infolist():
                    data = zf.read(info)
                    self.by_crc.setdefault(zlib.crc32(data) & 0xffffffff, data)
                    self.by_name.setdefault(info.filename.lower(), data)

    def get(self, name, crc):
        if crc is not None and crc in self.by_crc:
            return self.by_crc[crc]
        raise KeyError(f'{name} (crc {crc:08x})' if crc is not None else name)


def mcu_type(regions):
    """The I/O MCU from the set's own ROM table: its external-EPROM region tag."""
    tags = [r['tag'] for r in regions]
    if 'c68mcu:external' in tags:
        return 'c68'
    if 'c65mcu:external' in tags:
        return 'c65'
    raise SystemExit('no I/O MCU region')


def zip_chain(name, gm):
    chain = [name + '.zip']
    p = gm[name]['parent']
    while p:
        chain.append(p + '.zip')
        p = gm[p]['parent']
    return chain + ['namcoc65.zip', 'namcoc68.zip']


# ns2_video's board code by MAME machine config (docs/PLAN.md 2.4)
BOARDS = {'finallap': 1, 'finallap_c68': 1, 'finalap2': 1, 'finalap3': 1, 'base_fl': 1,
          'metlhawk': 2, 'sgunner': 3, 'sgunner2': 3, 'suzuka8h': 4, 'luckywld': 5}


# the control mode (config byte 33) and MCUB's and MCUH's idle values (bytes
# 34-35; MAME reads a bit no field defines as 0) by the set's MAME input
# ports (namcos2.cpp; the idle values as MAME's captures read them): AN5
# wheel, AN6 brake, AN7 accelerator; the guns' channels as their ports
CONTROLS = {
    'finallap': (0x05, 0xff, 0xff),   # wheel, pedals, toggled gear (MCUH 5); no Start
    'finalap3': (0x05, 0xff, 0xff),
    'fourtrax': (0x15, 0xff, 0xff),   # the same, Start on MCUB 7/6
    'dirtfox':  (0x21, 0xa0, 0xff),   # wheel, pedals, gears on MCUB 5 (down) / 7 (up)
    'suzuka':   (0x11, 0xc0, 0xff),   # wheel, pedals, Start
    'gollygho': (0x82, 0xff, 0xff),   # guns AN0-3, triggers MCUB 5/4
    'bubbletr': (0xc2, 0xff, 0xff),   # the same, reversed (its crosshair's scale -1)
    'sgunner':  (0x12, 0xff, 0xff),   # guns AN4/5 X, AN6/7 Y; triggers MCUH 5/4, bombs 3/2
    'luckywld': (0x2a, 0xff, 0xff),   # wheel, pedals and guns AN4 X1, AN2 Y1, AN3 X2, AN1 Y2; fire MCUH 5/4
    'metlhawk': (0x03, 0xc0, 0xa0),   # stick AN6 X, AN5 Y, AN7 lever; B1 MCUH 5, B2 MCUH 7
    'assault':  (0x04, 0xff, 0xff),   # two 4-way sticks a player: MCUB, MCUH, MCUDI0
}


# the speaker gains, x128 (config bytes 36-37: the C140, the YM2151), by MAME
# machine config (namcos2.cpp): base and the rest C140 0.75, YM2151 0.80;
# base2 (and assaultp) and metlhawk C140 1.0; base3 C140 0.45, YM2151 1.0
GAINS = {'base2': (1.0, 0.80), 'assaultp': (1.0, 0.80), 'metlhawk': (1.0, 0.80), 'base3': (0.45, 1.0)}


def gains(config):
    c, y = GAINS.get(config, (0.75, 0.80))
    return bytes([round(c * 128), round(y * 128)])


def config_block(name, sets=None, gm=None):
    """The core's configuration of a set, 48 bytes at image 0x00D6000 (the
    MiSTer top latches it from the download; not ROM data):
      0-1  'N2'
      2    board code [2:0], C68 [3], finalap2/3 tiles [4], Final Lap
           sprites [5], Metal Hawk wiring [6], Lucky & Wild wiring [7]
      3    the key custom's mode [1:0]; the data ROM's second megabyte has
           its even [4] / odd [5] bytes 0 (MAME loads the other lane only,
           rthun2 and suzuka8h: ns2_mem drom_empty); the set is ROT180 [6]
      4-20 its table: entry i's {valid, value[15:0]} at bits 17i.. (LSB first)
      21-32 MAME's power-on AN0-AN7 and MCUDI0-MCUDI3 (tools/ns2_ports.py)
      33   the control mode (rtl/ns2_controls.sv, CONTROLS by the set's
           MAME input ports): [1:0] 0 digital, 1 wheel and pedals, 2 light
           guns, 3 Metal Hawk's stick; [2] digital: Assault's twin
           sticks, wheel: a toggled gear shift; [3] Lucky
           & Wild; guns: [5:4] their channels, [6] reversed, [7] the
           triggers on MCUB; wheel and pedals: [4] Start on MCUB, [5] the
           gears on MCUB (Dirt Fox)
      34-35 MCUB's and MCUH's idle values (modes other than 0)
      36-37 the C140's and the YM2151's speaker gains x128 (GAINS)"""
    import ns2_keys
    sets = sets or parse()
    gm = gm or games()
    g = gm[name]
    b = BOARDS.get(g['config'], 0)
    b |= (mcu_type(sets[name]) == 'c68') << 3
    b |= name.startswith(('finalap2', 'finalap3')) << 4
    b |= (g['config'] == 'finallap') << 5
    b |= (g['init'] == 'init_metlhawk') << 6
    b |= (g['init'] == 'init_luckywld') << 7
    mode, tab = ns2_keys.table(name, gm)
    lanes = {ld['offset'] % 2 for r in sets[name] if r['tag'] == 'data_rom' for ld in r['loads']
             if not ld['nodump'] and ld['offset'] >= 0x100000}
    if lanes:
        mode |= (0 not in lanes) << 4 | (1 not in lanes) << 5
    mode |= (g['rotation'] == 'ROT180') << 6
    bits = 0
    for i, (ok, v) in enumerate(tab):
        bits |= ((int(ok) << 16) | (v & 0xffff)) << (17 * i)
    import ns2_ports
    return (b'N2' + bytes([b, mode]) + bits.to_bytes(17, 'little') + bytes(ns2_ports.ports(name))
            + bytes(CONTROLS.get(g['inputs'], (0, 0xff, 0xff))) + gains(g['config']) + bytes(10))


def build_region(region, files):
    buf = bytearray([region['erase']]) * region['size']
    for ld in region['loads']:
        if ld['nodump']:
            continue
        data = files.get(ld['file'], ld['crc'])[:ld['size']]
        for i, b in enumerate(data):
            a = ld['offset'] + i * ld['width']
            if a < len(buf):
                buf[a] = b
    return bytes(buf)


def build(name, sets=None, gm=None):
    """The set's regions (MAME's bytes) and its download image."""
    sets = sets or parse()
    gm = gm or games()
    files = Files(zip_chain(name, gm))
    regions = {}
    for r in sets[name]:
        if r['tag'] in IGNORED:
            continue
        regions[r['tag']] = build_region(r, files)
    zf, fn, size, crc = DEVICE_ROMS[mcu_type(sets[name])]
    regions['mcu_int'] = files.get(fn, crc)[:size]
    regions['config'] = config_block(name, sets, gm)
    img = bytearray(TOTAL)
    # MAME's EEPROM without a default table is all 1s (namcos2.cpp: NVRAM
    # DEFAULT_ALL_1)
    if 'nvram' not in regions:
        _, off, size = [l for l in LAYOUT if l[0] == 'nvram'][0]
        img[off:off + size] = b'\xff' * size
    for tag, data in regions.items():
        key = ALIASES.get(tag, tag)
        ent = [l for l in LAYOUT if l[0] == key]
        if not ent:
            raise SystemExit(f'{name}: region {tag} has no place in the image layout')
        _, off, size = ent[0]
        if len(data) > size:
            raise SystemExit(f'{name}: region {tag} is {len(data):#x}, the layout allows {size:#x}')
        if tag in MIRRORED and len(data) < size:
            # MAME takes a graphics code modulo the element count (tilemap.h,
            # drawgfx): the region repeats through its slot, so the core's
            # fetches wrap the same way (Golly Ghost's tiles are 384 KB)
            data = (data * (size // len(data) + 1))[:size]
        img[off:off + len(data)] = data
    return regions, bytes(img)


# Board wiring MAME applies in software after loading (driver inits). The
# image keeps the ROM files' own bytes; the core reproduces the wiring in its
# fetch path, and these functions are that path's specification (the region
# check applies them before comparing with MAME).
def _metlhawk_sprite(d):
    data = bytearray(d)
    for i in range(0, len(data), 32 * 32):
        for j in range(0, 32 * 32, 32 * 4):
            for k in range(0, 32, 4):
                a = i + j + k + 32
                v = data[a]
                data[a], data[a + 3], data[a + 2], data[a + 1] = data[a + 3], data[a + 2], data[a + 1], v
                a += 32
                data[a], data[a + 2] = data[a + 2], data[a]
                v = data[a + 1]   # MAME's `v` carries this byte into the next row
                data[a + 1], data[a + 3] = data[a + 3], data[a + 1]
                a += 32
                data[a], data[a + 1], data[a + 2], data[a + 3] = data[a + 1], data[a + 2], data[a + 3], v
                a = i + j + k
                for l in range(4):
                    data[a + l + 32], data[a + l + 32 * 3] = data[a + l + 32 * 3], data[a + l + 32]
    return bytes(data)


def _bitrev(d):
    return bytes(int(f'{b:08b}'[::-1], 2) for b in d)


WIRING = {   # init function -> {region: transform}
    'init_metlhawk': {'sprite': _metlhawk_sprite},
    'init_luckywld': {'c169roz:mask': _bitrev},
}


if __name__ == '__main__':
    sets, gm = parse(), games()
    for n in sys.argv[1:] or sorted(sets):
        regs, img = build(n, sets, gm)
        print(n, gm[n]['config'], mcu_type(sets[n]), ' '.join(f'{t}:{len(d):#x}' for t, d in regs.items()))
