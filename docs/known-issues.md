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

## NS2-2 — How MAME's picture relates to its state (closed, measured)

The reference renderer (`tools/ns2_model.py`) reproduces MAME's pictures
from the captured state (`sim/oracle/ns2_capture.lua`,
`tools/ns2_capture.py`). Getting it exact needed five facts about MAME, each
measured:
- **The pairing:** picture F+1 is state F's composition, coloured with state
  F+1's palette. The screen bitmap is `ind16`, and `screen:pixels()` applies
  the palette when it is called (`screen_device::pixels`), as GN-2 / MS1Z-5.
- **Black:** an empty pixel is the palette's own black entry
  (`palette_t::black_entry()`: 0x2000 x groups, below 65536), not pen 0. An
  earlier model used pen 0, which is usually black. It failed exactly on the
  frames where a game had set pen 0 to a colour: dsaber, phelios, rthun2 and
  sws93, 5 to 60 frames each.
- **Banding:** MAME splits the picture with `update_partial` at the POSIRQ
  line, P = (C116 reg 5 - 32) & 0xff, or P - 1 for `init_burnforc` and
  `init_suzuk8h2`. Each band uses the registers of the moment MAME drew it:
  state F-1 plus frame F's register writes before that line. The capture logs
  every video-register write with its line.
- **Both CPUs:** the slave 68000 makes per-line register writes too (Burning
  Force's line scroll, Finest Hour), so the taps are on both CPUs. With the
  master alone, Finest Hour matched 3036 of 3599 frames; with both it matches
  3598.
- **Boot:** from a fresh EEPROM a game stops at "35 WARNING 00180040 EXIT = 1P
  START". `sim/oracle/ns2_boot.lua` presses P1 Start at frames 300-305, as the
  core's user would.

**Result, 3,600-frame attract captures:**

| set | exact frames |
|---|---|
| burnforc | 3599 / 3599 |
| rthun2 | 3599 / 3599 |
| dsaber | 3599 / 3599 |
| phelios | 3599 / 3599 |
| sws93 | 3599 / 3599 |
| finehour | 3598 / 3599 |
| assault | 3578 / 3599 |

The frames that are not exact are all explained by MAME, not by the model:
- `assault` frames 1-20 are MAME's boot screen before its first draw (all
  0x00ffff);
- `assault` 2022 is 167 pixels of line 0;
- `finehour` 3580 is 161 pixels of one sprite. The game rewrites the sprite
  bank mid-frame. The model takes VRAM from state F for every band (only the
  registers are logged per line), so a VRAM change between bands is outside
  what it models.

## NS2-3 — D3: the SDRAM bandwidth gate (closed, measured)

`sim/rtl/sdram_probe` runs `jtframe_sdram64` against
`sim/models/sdram_model_burst.sv`, a burst SDRAM model with a mode register
and tRCD/tRP/tRAS/tRC/tRRD checks. Four generators each saturate a bank or
issue at a fixed rate, with sequential, random or replayed addresses. The
replayed addresses are the fetches of captured frames (`tools/ns2_load.py
--dump`). Every returned word is checked.

**Findings:**
- **The model had a bug of its own.** The read column was an integer
  expression inside a `{}` concatenation, which widened it and pushed the row
  and bank out of the index. Every row crossing read row 0. It is now sized
  first.
- **`jtframe_sdram64` loses a READ.** A bank in PRE_RD moved to READ on
  `bg && !all_dqm`, but the READ command (`do_read`) also waits for the data
  bus (`all_dbusy`). When another bank's burst held the bus, the bank
  advanced without issuing the command. It then raised `dok` on another
  bank's data: 4-7 bad words per 10 ms of replay. It shows under randomised
  arbitration (`BAPRIO=0`). The local fix leaves PRE_RD only on `do_read`
  (`docs/provenance.md`). Since the fix: 0 bad words in every run.
- **Rates:**
  - fixed priority (`BAPRIO=1`) starves banks 2 and 3 completely under load;
    randomised arbitration shares the bandwidth fairly;
  - a lone bank reaches 6.36 M random bursts/s (14 clk average latency);
  - four banks, all saturated with random reads, reach 13.5 M/s;
  - refresh debt is paid in one block every four lines under saturation, a
    stall of about 420 clk, which the fetch FIFOs must absorb.
- **Q3 and the gate:** the ROZ ROM is duplicated in two banks, and the core
  adds a per-tile mask class, a mask cache and a tile-row cache. With those,
  the 1.5x gate passes with every backlog at 12 requests or fewer. The
  numbers and the bank layout are in docs/PLAN.md 2.3.

## NS2-4 — Q2 and the M10K probe: the work RAMs and the budget (closed, measured)

**Q2, the slave's RAM.** MAME maps 256 KB at 0x100000-0x13ffff for the slave,
but its own board notes give 100000-10FFFF, 64 KB, as for the master.
- `sim/oracle/ns2_ramuse.lua` counts each 1 KB page's reads and writes by each
  68000 over 22 sets.
  - During boot, most sets touch all 256 KB: the RAM test.
  - After frame 600, every set stays within the first 64 KB, except that
    Assault uses pages 0x3f and 0x40, a work area across 0x110000.
- MAME with the slave RAM as 64 KB mirrored over the window
  (`NS2_SLAVE_RAM64`, `tools/mame-patches/ns2-oracle.patch`) gives pictures
  identical to the 256 KB map on all 12 sets tried. The sets cover every board
  type (std, fl, mh, sg, suz, lw), for 3600 frames each, comparing every 2nd
  frame. The boot RAM tests pass, and Assault's work area lands on page 0 of
  the mirror, which it does not otherwise use.
- **The core gives the slave 64 KB, mirrored.**

**The C123 tilemap RAM** (64 KB) is used to its top after boot by 14 of 16
sets (the rest reach 0xc7-0xd4 of 0xff): the games keep work data beyond the
planes. It cannot be trimmed.

**The M10K probe** (`sim/quartus/m10k_probe`) fits the standard board's arrays
at their real port shapes.
- It first duplicated every array: two read ports plus a write port infer as
  two simple dual-port copies. Byte-lane writes from two processes do not
  infer as true dual port either. The probe uses 8-bit lanes and Intel's
  template (a port reads its own new data), which the core's RAMs must also
  use.
- Result: 401 blocks. With the CPUs, jt51 and everything outside the core,
  that is 527 of 553. The consequences are in docs/PLAN.md Appendix F.
