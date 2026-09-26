#!/usr/bin/env python3
"""Generate the Arcade-NamcoSystem2_MiSTer .mra files from tools/ns2_romdata.py.

    tools/ns2_mra.py [SET ...]       write releases/*.mra (clones under
                                     releases/_alternatives/_<parent>/)
    tools/ns2_mra.py --check [SET]   assemble each .mra the way MiSTer does and
                                     compare it with ns2_romdata.build()

One image a set through the ROM download (ioctl index 0), laid out as
ns2_romdata.LAYOUT (docs/PLAN.md Appendix D). Each region is its MAME
ROM_LOADs in address order:
  - a ROM_LOAD is a <part>;
  - ROM_LOAD16_BYTE / ROM_LOAD32_BYTE lanes sharing a span are an
    <interleave> (map: the rightmost character is the lowest-addressed output
    byte, MS1BCD's measurement);
  - gaps are <part repeat> fills of the region's erase byte;
  - a graphics region smaller than its slot repeats through it, as MAME
    takes a code modulo the element count (ns2_romdata MIRRORED).
The configuration block (config_block) is an inline <part>. The default
NVRAM, where MAME has one, is a region of the image; the user's .nvm is
<nvram index="4">.

DIPs come from MAME's own -listxml (MS1-47): <switches> byte 0 is the DSW
port (the MCU's $2000).

The bitstream a set needs (docs/PLAN.md 2.4): NamcoS2 for the standard and
Final Lap boards; Metal Hawk and the C355 boards are later bitstreams, and
are skipped here until they exist.

Every file written is parsed as XML first (NMKBP964: a '--' inside a comment
broke strict parsers).
"""
import argparse, os, subprocess, sys, zipfile, zlib
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as _xml_escape

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ns2_romdata as R

ROOT = os.path.join(HERE, '..')
RELEASES = os.path.join(ROOT, 'releases')
MAME = os.path.expanduser('~/mame/mame')
RBF = {0: 'NamcoS2', 1: 'NamcoS2', 2: 'NamcoS2_MH', 3: 'NamcoS2_NB', 4: 'NamcoS2_NB', 5: 'NamcoS2_NB'}   # board code -> bitstream
BUILT = {'NamcoS2'}                          # the bitstreams that exist: the default set list


def x(v): return _xml_escape(str(v))
FAT_FORBIDDEN = {':': '-', '/': '-', '\\': '-', '?': '', '*': '', '<': '', '>': '', '|': '-', '"': "'"}
def fat_safe(desc): return ''.join(FAT_FORBIDDEN.get(c, c) for c in desc).rstrip('. ')


# ------------------------------------------------------------------ the parts
def region_parts(region, files):
    """A region's parts: [('file', name, crc, length) | ('fill', byte, count) |
    ('ilv', width, [(lane, name, crc, length)])], covering region['size']."""
    groups = {}          # (base, span, width) -> {lane: load}
    for ld in region['loads']:
        if ld['nodump']:
            continue
        data = files.get(ld['file'], ld['crc'])
        n = min(ld['size'], len(data))
        w = ld['width']
        lane = ld['offset'] % w
        base = ld['offset'] - lane
        key = (base, n * w, w)
        g = groups.setdefault(key, {})
        # a later load over the same span wins, as MAME applies them in order
        # (sws92g's data ROM)
        g[lane] = (ld['file'], ld['crc'], n, len(data))
    out, at = [], 0
    for (base, span, w) in sorted(groups):
        if base < at:
            raise SystemExit(f"{region['tag']}: overlapping loads at {base:#x}")
        if base > at:
            out.append(('fill', region['erase'], base - at))
        g = groups[(base, span, w)]
        if w == 1:
            name, crc, n, flen = g[0]
            out.append(('file', name, crc, n))
        else:
            if len(g) != w:
                # a lane MAME leaves at 0 (the C140's odd bytes, rthun2's and
                # suzuka8h's data ROM): a copy of a loaded lane stands in, and
                # the core's download writes 0 there (ns2_mem drom_empty)
                if w != 2 or region['tag'] not in ('c140', 'data_rom'):
                    raise SystemExit(f"{region['tag']}: {w}-byte interleave at {base:#x} lacks lanes {sorted(set(range(w)) - set(g))}")
                g = {0: g.get(0, g.get(1)), 1: g.get(1, g.get(0))}
            out.append(('ilv', w, [(lane, g[lane][0], g[lane][1], g[lane][2]) for lane in sorted(g)]))
        at = base + span
    if at < region['size']:
        out.append(('fill', region['erase'], region['size'] - at))
    return out, region['size']


def part_len(p):
    return p[3] if p[0] == 'file' else p[2] if p[0] == 'fill' else p[1] * p[2][0][3]


def truncate(parts, n):
    """The parts' first n bytes (a mirrored region's last, partial copy)."""
    out = []
    for p in parts:
        if n <= 0:
            break
        l = part_len(p)
        if l <= n:
            out.append(p)
        elif p[0] == 'file':
            out.append(('file', p[1], p[2], n))
        elif p[0] == 'fill':
            out.append(('fill', p[1], n))
        else:
            raise SystemExit('a mirrored copy ends inside an interleave')
        n -= l
    return out


def image_parts(name, sets, gm):
    """The whole image's parts, with a comment per region."""
    files = R.Files(R.zip_chain(name, gm))
    regs = {r['tag']: r for r in sets[name] if r['tag'] not in R.IGNORED}
    zf, fn, size, crc = R.DEVICE_ROMS[R.mcu_type(sets[name])]
    placed = []
    for tag, r in regs.items():
        key = R.ALIASES.get(tag, tag)
        ent = [l for l in R.LAYOUT if l[0] == key]
        if not ent:
            raise SystemExit(f'{name}: region {tag} has no place in the image layout')
        _, off, slot = ent[0]
        parts, rlen = region_parts(r, files)
        if tag in R.MIRRORED and rlen < slot:
            full, rest = divmod(slot, rlen)
            parts = parts * full + truncate(parts, rest)
            rlen = slot
        placed.append((off, rlen, tag, parts))
    placed.append((0x00C8000, size, 'mcu_int', [('file', fn, crc, size)]))
    placed.append((0x00D6000, 0x30, 'config', [('hex', R.config_block(name, sets, gm))]))
    if 'nvram' not in regs:
        # MAME's EEPROM without a default table is all 1s (NVRAM DEFAULT_ALL_1)
        placed.append((0x00D1000, 0x2000, 'nvram (MAME: all 1s)', [('fill', 0xFF, 0x2000)]))
    placed.sort()
    out, at = [], 0
    for off, rlen, tag, parts in placed:
        if off < at:
            raise SystemExit(f'{name}: {tag} overlaps the previous region')
        if off > at:
            out.append(('fill', 0, off - at))
        out.append(('comment', f'{tag}: {rlen:#x} bytes at image {off:#09x}'))
        out += parts
        at = off + rlen
    if at < R.TOTAL:
        out.append(('fill', 0, R.TOTAL - at))
    return out, zf


# ------------------------------------------------------------------ XML
def dips_from_mame(setname):
    xml = subprocess.run([MAME, '-listxml', setname], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    mach = next(m for m in root.iter('machine') if m.get('name') == setname)
    default, dips = 0xFF, []
    for sw in mach.iter('dipswitch'):
        if sw.get('tag') not in ('DSW', ':DSW'):
            continue
        mask = int(sw.get('mask'))
        lo = (mask & -mask).bit_length() - 1
        hi = mask.bit_length() - 1
        ids = ['Undefined'] * (1 << (hi - lo + 1))
        for v in sw.iter('dipvalue'):
            ids[int(v.get('value')) >> lo] = v.get('name')
            if v.get('default') == 'yes':
                default = (default & ~mask) | int(v.get('value'))
        bits = f'{lo}' if lo == hi else f'{lo},{hi}'
        dips.append((bits, sw.get('name'), ids))
    return default & 0xFF, dips


def mra_text(name, sets, gm):
    g = gm[name]
    parts, devzip = image_parts(name, sets, gm)
    zips = '|'.join(R.zip_chain(name, gm)[:-2] + [devzip])
    has_nv = any(r['tag'] == 'nvram' for r in sets[name])
    default, dips = dips_from_mame(name)
    rot = {'ROT0': 'horizontal', 'ROT90': 'vertical (cw)', 'ROT180': 'horizontal', 'ROT270': 'vertical (ccw)'}[g['rotation']]
    L = ['<!--',
         f"  {x(g['desc'])}: {x(g['manufacturer'])} {g['year']}, MAME namco/namcos2.cpp ({name}).",
         '  Generated by tools/ns2_mra.py from tools/ns2_romdata.py; do not hand-edit.',
         '  One image through the ROM download (docs/PLAN.md Appendix D); the core',
         '  reads its configuration from the block at 0x00D6000.',
         '-->',
         '<misterromdescription>',
         f"  <name>{x(g['desc'])}</name>",
         '  <mratimestamp>202609260000</mratimestamp>',
         '  <mameversion>0289</mameversion>',
         f'  <setname>{name}</setname>',
         f"  <year>{g['year']}</year>",
         f"  <manufacturer>{x(g['manufacturer'])}</manufacturer>",
         '  <category>Arcade</category>',
         f"  <rbf>{RBF[R.BOARDS.get(g['config'], 0)]}</rbf>",
         f'  <rotation>{rot}</rotation>',
         '']
    if g['parent']:
        L.insert(L.index(f'  <setname>{name}</setname>') + 1, f"  <parent>{g['parent']}</parent>")
    L.append(f'  <switches default="{default:02X}">')
    for bits, nm, ids in dips:
        L.append(f'    <dip bits="{bits}" name="{x(nm)}" ids="{x(",".join(ids))}"/>')
    L += ['  </switches>', '',
          '  <buttons names="Button 1,Button 2,Button 3,Start,Coin,Service" default="A,B,X,Start,R,L"/>', '',
          f'  <rom index="0" zip="{zips}" md5="none">']
    for p in parts:
        if p[0] == 'comment':
            L.append(f'    <!-- {p[1]} -->')
        elif p[0] == 'fill':
            L.append(f'    <part repeat="{p[2]:#x}">{p[1]:02X}</part>')
        elif p[0] == 'hex':
            L.append('    <part>' + ' '.join(f'{b:02X}' for b in p[1]) + '</part>')
        elif p[0] == 'file':
            L.append(f'    <part crc="{p[2]:08x}" name="{x(p[1])}" length="{p[3]:#x}"/>')
        else:
            w, lanes = p[1], p[2]
            L.append(f'    <interleave output="{8 * w}">')
            for lane, nm, crc, n in lanes:
                m = ''.join('1' if k == lane else '0' for k in reversed(range(w)))
                L.append(f'      <part crc="{crc:08x}" name="{x(nm)}" length="{n:#x}" map="{m}"/>')
            L.append('    </interleave>')
    L += ['  </rom>', '', '  <nvram index="4" size="8192"/>', '</misterromdescription>', '']
    text = '\n'.join(L)
    ET.fromstring(text)
    return text, has_nv


# ------------------------------------------------------------------ the check
def assemble(text, name, gm):
    """The image MiSTer's mra loader builds from the text."""
    root = ET.fromstring(text)
    rom = root.find('rom')
    files = R.Files(rom.get('zip').split('|'))
    def data(p):
        d = files.get(p.get('name'), int(p.get('crc'), 16))
        return d[:int(p.get('length'), 16)] if p.get('length') else d
    out = bytearray()
    for el in rom:
        if el.tag == 'part':
            if el.get('name'):
                out += data(el)
            else:
                b = bytes.fromhex(el.text)
                out += b * int(el.get('repeat', '1'), 0)
        elif el.tag == 'interleave':
            w = int(el.get('output')) // 8
            ps = [(p.get('map'), data(p)) for p in el]
            # each part gives the map's nonzero count of bytes a word
            words = min(len(d) // sum(c != '0' for c in m) for m, d in ps)
            buf = bytearray(words * w)
            for m, d in ps:
                nb = sum(c != '0' for c in m)
                for k, c in enumerate(reversed(m)):
                    if c != '0':
                        buf[k::w] = d[int(c) - 1::nb][:words]
            out += buf
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sets', nargs='*')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    sets, gm = R.parse(), R.games()
    names = a.sets or sorted(n for n in sets if RBF[R.BOARDS.get(gm[n]['config'], 0)] in BUILT)
    bad = 0
    for n in names:
        text, has_nv = mra_text(n, sets, gm)
        if a.check:
            img = bytearray(assemble(text, n, gm))
            # what the core's download does to the stand-in lanes (ns2_mem)
            cfg = R.config_block(n, sets, gm)
            img[0x0300001:0x0500000:2] = bytes(len(img[0x0300001:0x0500000:2]))
            for lane, bit in ((0, 4), (1, 5)):
                if cfg[3] >> bit & 1:
                    img[0x0200000 + lane:0x0300000:2] = bytes(len(img[0x0200000 + lane:0x0300000:2]))
            img = bytes(img)
            _, ref = R.build(n, sets, gm)
            ok = img == ref
            if not ok:
                bad += 1
                d = next((i for i in range(min(len(img), len(ref))) if img[i] != ref[i]), min(len(img), len(ref)))
                print(f'{n}: DIFFERS at {d:#x} (image {len(img):#x}, reference {len(ref):#x})')
            else:
                print(f'{n}: equal ({len(img):#x} bytes)')
            continue
        g = gm[n]
        top = n if not g['parent'] else g['parent']
        d = RELEASES if not g['parent'] else os.path.join(RELEASES, '_alternatives', '_' + fat_safe(gm[top]['desc']))
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, fat_safe(g['desc']) + '.mra')
        open(path, 'w').write(text)
        print(path)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
