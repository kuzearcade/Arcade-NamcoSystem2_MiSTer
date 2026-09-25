# Known issues and findings (NS2-n)

Every finding is a measurement against MAME 0.289 (`~/mame` @ 017b8670f0a),
with its evidence and its status.

## NS2-1 — The ROM table is MAME's, byte for byte, for all 61 sets (closed, measured)

`tools/ns2_romdata.py` parses every `ROM_START` block of
`namco/namcos2.cpp`. The driver's own `NAMCOS2_*_LOAD_*` macros are expanded
from their `#define`s, and each set's regions are rebuilt from the zips:
- the byte, 16-bit and 32-bit interleaves;
- the `ROM_RELOAD` mirrors;
- the erase fills;
- the I/O MCU's internal ROM from `namcoc65.zip` / `namcoc68.zip`, chosen by
  the set's own region tag (`c65mcu:external` or `c68mcu:external`).

`tools/ns2_regions.py` runs MAME with `sim/oracle/ns2_regions.lua`, which
dumps every region MAME loaded, and compares byte for byte.
- **Result: 61 of 61 sets, every region identical.**
- MAME's 16-bit big-endian regions hold their bytes unswapped.
- 44 sets use the C65 (HD63705) and 17 the C68 (M37450).
- `finalap3a`'s extra `unknown` region is never read by MAME and is
  ignored, as are the PAL dumps.

**Two sets are wired differently, and MAME fixes that in software** after
loading (driver inits):
- `metlhawk`: the sprite bytes are permuted within each 32-byte row group
  (`init_metlhawk`);
- `luckywld`: each C169 mask byte is bit-reversed (`init_luckywld`).

The download image keeps the ROM files' bytes, which is all an `.mra` can
produce. The core reproduces the wiring in its fetch paths, as the real
board's wiring does. `ns2_romdata.WIRING` is that path's specification, and
the check applies it before comparing.
