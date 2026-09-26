# Arcade-NamcoSystem2_MiSTer — Project Plan (approved 2026-09-25; implementation under way)

**Approved with the recommended option for every decision (D1-D8).** B1 is
resolved: `namcoc65.zip`, `namcoc68.zip` and `sgunner.zip` are in
`mame_roms`. **Final Lap 1/2/3 and Four Trax were added (16 sets) and are in
scope**: sprites (A, Final Lap variant) + the C45 road, no ROZ. They join the
standard bitstream: the road RAM and the ROZ RAM are both 128 KB and are one
array, selected by the mode byte (D1 as revised in 2.4). Every set now
verifies except `valkyrie`, which lacks only its default `valkyrie.nv`.

A MiSTer core for **Namco System 2** (1987-1993), built the way
Arcade-NMK16_MiSTer, Arcade-SandScrp_MiSTer, Arcade-JalecoMS1BCD_MiSTer,
Arcade-JalecoMS1Z_MiSTer, Arcade-NMKBP964_MiSTer and Arcade-GingaNin_MiSTer
were built:

- MAME is the reference, at a pinned commit.
- Every claim about the board is a measurement against MAME, recorded as a
  numbered finding (NS2-n) in `docs/known-issues.md`.
- Each milestone has a gate, and a gate is a measurement, never a judgement.
- Nothing is committed that was derived from a ROM.

Reference: MAME `src/mame/namco/namcos2.cpp` (K. Wilkins) and its devices:
- `namcos2_v.cpp`, `namcos2_m.cpp`, `namcos2_sprite.cpp`, `namcos2_roz.cpp`;
- `namco_c123tmap`, `namco_c116`, `namco_c148`, `namco_c139`,
  `namco_c169roz`, `namco_c45road`;
- `shared/namco_c355spr`, `namco65`, `namco68`;
- `sound/c140`, `sound/ymopm`.

The pin is `~/mame` at `017b8670f0a` (2026-08-31), MAME 0.289, as the
siblings.

---

## 0. Facts that shape the plan

1. **The board is big.** Five CPUs, four emulated by MAME:
   - two 68000s (master and slave) at 12.288 MHz;
   - a 6809 at 2.048 MHz for sound;
   - an I/O MCU: HD63705 "C65" at 2.048 MHz, or M37450 "C68" at 8.192 MHz;
   - the serial-link CPU, which MAME does not emulate.

   All share a 2 KB dual-port RAM. The sound is a YM2151 plus a C140
   (24-voice PCM). The CPU board has six tilemaps (C123/C145):
   - four scrolling planes of 64x64 tiles;
   - two fixed planes of 36x28;
   - 8x8 tiles at 8 bits per pixel, with a 1-bit mask ROM.

   It also has the C116 palette and raster generator: 8,192 pens of 24 bits,
   a clip window, the position IRQ and shadow pens. A separate graphics board
   supplies sprites, ROZ and road layers.

2. **The graphics board varies by game** (driver notes and machine configs):

   | board | sprites | ROZ | road | local sets |
   |---|---|---|---|---|
   | standard | (A) `namcos2_sprite`: 128 of 16 banks, 16/32 px, x/y zoom, 8 bpp | (A) `namcos2_roz`: one 256x256 plane of 8x8 tiles | -- | 33 |
   | Metal Hawk | (A), Metal Hawk layout | (B) C169, two planes of 16x16 tiles | -- | 2 |
   | Steel Gunner 2 | (B) C355 (as Namco NB-1) | -- | -- | 3 (1 blocked) |
   | Suzuka 8 Hours 1 / 2 | (B) C355 | -- | C45 | 4 |
   | Lucky & Wild | (B) C355 | (B) C169 | C45 | 2 |
   | Final Lap 1 / 2 / 3, Four Trax | (A), Final Lap variant | -- | C45 | 16 (added after the draft) |

3. **The romsets** (`mame_roms`, 44 zips) cover 18 parents and 26 clones:
   - Assault, Ordyne, Mirai Ninja, Phelios, Dirt Fox, Valkyrie no Densetsu,
     Finest Hour, Burning Force, Marvel Land, Kyuukai Douchuuki, Dragon Saber,
     Golly! Ghost!, Rolling Thunder 2, Cosmo Gang, Bubble Trouble;
   - Super World Stadium, '92 and '93;
   - Metal Hawk, Steel Gunner 2, Suzuka 8 Hours 1 and 2, Lucky & Wild.

   `mame -verifyroms` fails every set for one of these reasons:
   - **the I/O MCU's internal ROM is a separate MAME device zip, and neither
     is here**: `namcoc65.zip` (`sys2mcpu.bin`, 8 KB; 32 sets) and
     `namcoc68.zip` (`c68.bin`, 32 KB; 12 sets);
   - `sgunnerj` also needs its parent `sgunner.zip`, which is absent.

   Beyond those, only undumped PALs, the default `.nv` files of `valkyrie`
   and `sgunner`, and a "needs redump" flag on `marvlandup` are missing.
   **Blocker B1: please add `namcoc65.zip`, `namcoc68.zip` and, for
   `sgunnerj`, `sgunner.zip`.** Without them MAME cannot run as the oracle,
   and a real MCU cannot run in the core.

4. **Clocks** all divide a 49.152 MHz crystal:
   - the 68000s at /4 = 12.288 MHz;
   - the pixel clock at /8 = 6.144 MHz;
   - the 6809 and the C65 at /24 = 2.048 MHz;
   - the C68 at /6 = 8.192 MHz;
   - the C140 at /2304 = 21.333 kHz;
   - the YM2151 alone, on 3.579545 MHz.

   The screen is 384 x 264 dots with 288 x 224 visible, 60.606 Hz. A
   **49.152 MHz `clk_sys`** makes all of them exact except the YM2151, which
   gets a rational accumulator (MS1-28's width lesson).

5. **Protection: the key custom** at `0xD00000` (`0xA00000` on Steel Gunner
   2, `0xF00000` on Suzuka and Lucky & Wild).
   - Per-game constants, and two stateful handshakes (Marvel Land, Rolling
     Thunder 2); `namcos2_m.cpp`.
   - **Every other read returns `machine().rand()`**, and Rolling Thunder 2
     reads `$d00006` as its random number source. MAME's randomness cannot be
     reproduced in RTL, so the oracle needs a patch: a documented LFSR in
     MAME's key custom, mirrored in the core (D5).

6. **Interrupts**: the C148 on each 68000 encodes VBLANK, POSIRQ (the C116
   raster line), master/slave IRQs, the serial IRQ and EXIRQ, each at a
   programmable level.
   - The master C148 also resets the sound CPU and holds the slave and the
     MCU in reset.
   - MAME uses autovectors. **The core answers IACK with DTACK and the vector
     number 24 + level**. GN-10 found that a VPA cycle syncs to fx68k's
     internal E clock and breaks savestate determinism.

7. **MAME renders with partial updates at the POSIRQ line**
   (`screen_scanline` calls `update_partial`). Its pictures therefore already
   contain mid-frame splits, which suits a line renderer better than on the
   siblings (MP-4, GN-7). MAME's own TODO lists, among others:
   - Burning Force's POSIRQ is off by one;
   - Metal Hawk's ROZ does not wrap;
   - Finest Hour's ROZ colours are wrong;
   - Suzuka 8 Hours II crops some sprites.

   Each is a candidate "MAME is wrong" finding, recorded, never silently
   "fixed".

8. **NVRAM**: an 8 KB byte EEPROM at `0x180000` holds settings and high
   scores. Several sets ship a default `.nv` (with calibration data): Metal
   Hawk, Dirt Fox, Steel Gunner 2, Lucky & Wild. MiSTer's `.nvm` save
   replaces the hiscore module for this board (D6).

9. **Inputs** go through the MCU:
   - ports B, C and H (joysticks, buttons, coins, starts, service);
   - the DIP bank at `$2000`;
   - dials at `$3000`;
   - 8 analog channels.

   Assault uses twin sticks. Dirt Fox, Suzuka and Lucky & Wild use a wheel
   and pedals. Golly Ghost, Bubble Trouble, Steel Gunner 2 and Lucky & Wild
   use light guns. Golly Ghost and Bubble Trouble also drive diorama lamps
   and 7-segment displays; MAME marks them `MACHINE_REQUIRES_ARTWORK`.

10. **No MiSTer core for System 2 exists**, and no public FPGA C140 or
    M37450 was found. Nearby open work:
    - `jotego/jtcores` (GPL-3): `jt51` (YM2151, already in NMK16 and MS1BCD),
      `jt6805` (68705 only: 13-bit addresses, no HD63705 extras), and the
      Namco System 1 core (`cores/shouse`: C117, CUS30, key custom, a 6809 and
      a 63701 through `jt680x`);
    - `kyledlester/Namco_NA1_NA2_MiSTer` (GPL-3.0-or-later): `na1_c219.sv`
      (the C140's successor, a cross-check for our C140) and a KEYCUS model;
    - the siblings: fx68k, `mc6809is` (with GN-4's latch fix), `jt680x`,
      `sdram.sv`, the savestate engine, the three park monitors, CRT Adjust,
      hiscore, cheats and `video_retime`.

---

## 1. The hardware, from the driver

### 1.1 CPUs and clocks (`namcos2.cpp:1693-1746`)

| part | clock | notes |
|---|---|---|
| master 68000 | 12.288 MHz | program 256 KB, RAM 64 KB, EEPROM 8 KB, C148 |
| slave 68000 | 12.288 MHz | program 256 KB, RAM (MAME maps 256 KB; Q2), C148 |
| 6809 (MC6809E) | 2.048 MHz | 16 KB banked ROM window, YM2151, C140, DPRAM, 8 KB RAM; IRQ 120 Hz periodic in MAME (Q5); FIRQ from the C140 |
| C65 HD63705 | 2.048 MHz | 8 KB internal ROM + 32 KB external EPROM per set; ports, DSW, dials, ADC, DPRAM; INT at line 200 in MAME ("exact timing unknown": Q6) |
| C68 M37450 | 8.192 MHz | 32 KB internal ROM; same map shape; VBL ack at `$6000` |
| YM2151 | 3.579545 MHz | stereo |
| C140 | 21.333 kHz | 24 voices, 8-bit compressed or 12-bit linear, 2 MB voice ROM |
| screen | 6.144 MHz | 384 x 264, visible 288 x 224, 60.606 Hz |

MAME's quantum is 12,000 slices a second (6,000 on some boards). Assault
Plus needs 96,000 and an "overclocked" MCU for its mode select to work:
that is Q7, a timing question the RTL settles by construction.

### 1.2 Shared 68000 map (CPU board)

| range | device |
|---|---|
| `200000-3FFFFF` | data ROM (2 MB, shared) |
| `400000-41FFFF` | C123 tilemap RAM (64 KB, mirrored) |
| `420000-42003F` | C123 control: scroll, flip, priority, colour per plane |
| `440000-44FFFF` | C116 palette (byte lanes: R, G, B planes of 8 x 256) and registers (clip window, POSIRQ line) |
| `460000-47FFFF` | DPRAM (2 KB, low byte) |
| `480000-4BFFFF` | C139 serial RAM and registers (link play; stub) |

Private per CPU: `000000-03FFFF` ROM, `100000-` RAM, and the C148 at
`1C0000-1FFFFF`. The master also has the EEPROM at `180000` and the reset
outputs.

### 1.3 Graphics-board maps

| board | sprites | ROZ | road | key custom |
|---|---|---|---|---|
| standard | `C00000` RAM 16 KB, `C40000` gfx_ctrl (bank, ROZ colour and priority) | `C80000-C9FFFF` RAM 128 KB, `CC0000` control | -- | `D00000` |
| Metal Hawk | `C00000`, `E00000` gfx_ctrl | C169 `C40000-C4FFFF` (64 KB), `D00000-D0001F` | -- | -- |
| Steel Gunner 2 | C355 `800000-8141FF` | -- | -- | `A00000` |
| Suzuka / L&W | C355 `800000-8141FF`, position `900000` | L&W: C169 `C00000`, `D00000` | C45 `A00000-A1FFFF` (128 KB) | `F00000` |

### 1.4 Sound map (6809)

| range | device |
|---|---|
| `0000-3FFF` | banked audio ROM (bank = write to `C000` >> 4) |
| `4000-4001` | YM2151 |
| `5000-51FF`, `6000-61FF` (mirrors) | C140 |
| `7000-77FF` | DPRAM |
| `8000-9FFF` | RAM |
| `C000-FFFF` | ROM |

### 1.5 Video composition (`namcos2_v.cpp`)

- **Standard:** for each priority 0-7, the tilemaps of that priority, then
  the ROZ if gfx_ctrl's ROZ priority matches. Sprites go on top, mixed by
  their own 3-bit priority against the priority buffer.
  - Pen `0xffe` is a shadow: it sets bit `0x800` of the pixel below (C116
    shadow pens).
  - Pen `0xff` of each colour is transparent.
- **Metal Hawk, Suzuka, Lucky & Wild:** 16 priority steps. Even steps draw
  the tilemaps at priority/2; every step draws the road and the C169 at that
  priority; then the C355 sprites or the Metal Hawk sprites.
- **Clip:** the C116 registers 0-3 set the clip window (`- 0x4a`, `- 0x21`).
- **Tiles:** the C123 tile code is bit-swapped by `TilemapCB`. The ROZ tile
  callbacks are per board (`RozCB_metlhawk`, `RozCB_luckywld`).

### 1.6 ROM regions (largest set)

| region | size | where |
|---|---|---|
| master, slave programs | 256 KB each | SDRAM + cache |
| audio program | 128-256 KB | BRAM or SDRAM + cache (Q9) |
| MCU external EPROM | 32 KB | BRAM |
| MCU internal ROM | 8 KB (C65) or 32 KB (C68) | BRAM, from the device zip |
| sprites | 4 MB | SDRAM |
| tiles + mask | 4 MB + 512 KB | SDRAM |
| ROZ tiles (+ C169 mask) | up to 4 MB (+ 512 KB) | SDRAM (the bandwidth question, D3) |
| data ROM | 2 MB | SDRAM + cache |
| C140 voices | 2 MB | SDRAM |
| C45 road CLUT | 256 B | BRAM |
| default `.nv` | 8 KB | via the `.mra` NVRAM path |

Total at most about 17.5 MB, which fits the 32 MB SDRAM.

---

## 2. Architecture and reuse

### 2.1 Block diagram

```
          +-------------------------- ns2_core ---------------------------+
 ioctl -> | ns2_rom_hw (SDRAM streams, caches)                            |
          |  master 68000 (fx68k) --+                                     |
          |  slave  68000 (fx68k) --+-- ns2_bus: shared map, C148 x2,     |
          |                         |   DPRAM, key custom, EEPROM          |
          |  6809 (mc6809is) ------ ns2_sound: YM2151 (jt51), C140, banks  |
          |  I/O MCU (C65 or C68) - ns2_io: ports, DSW, ADC, guns          |
          |  ns2_video: C123 x6 layers, C116 palette/raster/POSIRQ,        |
          |             gfx board: sprites A | C355, ROZ A | C169, C45      |
          +---------------------------------------------------------------+
```

### 2.2 Clocks and raster (D4, recommended A)

- `clk_sys` is 49.152 MHz: fx68k phases every 2 clocks (12.288 MHz), the
  pixel clock is /8, the 6809 and C65 are /24, the C68 is /6.
- The YM2151 gets a 3.579545 MHz rational enable.
- SDRAM runs at 98.304 MHz (x2), the siblings' 2:1 ratio.
- The raster is 384 x 264 with 288 x 224 visible (60.606 Hz, MAME's). Its
  blanking position is fixed by M1 against MAME's pictures, and POSIRQ comes
  from the C116 registers.

### 2.3 Memory (D3, recommended A)

The central risk is **ROZ bandwidth**: one random 8-bit read from a 4 MB tile
ROM per displayed pixel.
- 288 reads per 62.5 us line is one every 217 ns.
- The siblings' `sdram.sv` serves one request per port at a time, measured at
  15 `clk_sys` (about 300 ns) on GingaNin's streams.

So the plan replaces it for the graphics streams:
- **A (recommended):** a bank-interleaved, pipelined SDRAM controller.
  - Candidate: vendor `jtframe_sdram64` from jtcores (GPL-3), or extend
    `sdram.sv` with 4-bank pipelining.
  - The ROZ tile ROM sits in its own banks, the sprite and tile ROMs in the
    others, and the CPU caches share what remains.
  - **M0's first probe** measures sustained random-read throughput in
    simulation against `sim/models/sdram_model.sv`. The gate is 1.5x the
    ROZ + tile + sprite load of the worst MAME frame (Q3).
- **B:** ROZ tiles through a per-line tile cache in BRAM (the ROZ plane of
  one line touches a bounded set of tiles). This depends on the game; kept as
  a fallback if A misses its gate.
- **C:** DDR3 for ROZ. Its latency is higher still (MP-8, MP-14); rejected
  for random reads, kept for bulk RAM (below).

**M0 result (NS2-3): A passes its gate with three additions.**
- The controller is `jtframe_sdram64` with randomised bank arbitration
  (`BAPRIO=0`) and one local fix: the probe found a lost READ, now fixed.
- The load per line (Q3, `tools/ns2_load.py`) in 64-bit bursts. Each figure is
  the worst sampled line of seven attract captures:

  | stream | worst line | where |
  |---|---|---|
  | ROZ | 288 (4.61 M/s) | Assault, zoomed out: one new burst per pixel, and no cache helps |
  | tiles | 220 (3.52 M/s) | Finest Hour: six planes of 36-37 tile rows |
  | masks | 220 (3.52 M/s) | as tiles |
  | sprites | 92 (1.47 M/s) | SWS '93 |

- The additions:
  - the ROZ ROM is stored twice, in banks 0 and 1, and the ROZ fetcher
    alternates between them;
  - the core keeps a 2-bit class per tile in BRAM (transparent, opaque or
    mixed: 128 Kbit, taken from the mask ROM while it loads). It fetches a
    mask only for a mixed tile, through a 256-entry cache: worst line 0.54 M/s;
  - a 256-entry tile-row cache: worst line 2.90 M/s.
- The bank layout: ROZ copies in banks 0 and 1, tiles in bank 2, and masks
  plus sprites in bank 3. It fits the 32 MB module, 8 MB per bank:

  | bank | contents | size |
  |---|---|---|
  | 0 | ROZ + the CPU programs + data ROM | 4 + 0.75 + 2 MB |
  | 1 | ROZ + C140 | 4 + 2 MB |
  | 2 | tiles + C123 and C169 masks | 4 + 1 MB |
  | 3 | sprites | 4 MB |
- **The gate:** each stream replays its worst frames at 1.5x its worst line,
  all four at once. The load is stacked from different games, which is
  stricter than any one game. Result: every backlog stays at 12 requests or
  fewer, with 0 bad words and 0 timing violations. The ceiling is about 1.6x.
- The CPU caches and C140 traffic are not in this load. They share the banks'
  spare time, and M2/M3 re-measure them on the real core.

On-chip RAM (M10K, 553 blocks) holds what the video reads every pixel:
- tilemap RAM (64 KB);
- sprite RAM (16 KB, or C355 about 82 KB);
- ROZ RAM (128 KB, or C169 64 KB);
- the palette (24 KB);
- the line buffers;
- DPRAM, EEPROM, sound RAM, MCU RAM and the cache arrays.

The two work RAMs are the swing items: master 64 KB, slave 64-256 KB (Q2).
The C45 road RAM (128 KB) adds to that. Appendix F budgets it; where it does
not fit, the work RAM goes to SDRAM with a cache (MS1BCD's shape) and is
measured for CPU speed (MP-13's method).

### 2.4 Bitstreams (D1, recommended A)

One bitstream cannot hold every graphics board: 2x fx68k, three CPUs, the
C140, jt51 and every video block at once would exceed ALMs and M10K. The
siblings' answer was NMK16's four bitstreams from one source tree
(`BOARD_*` parameters):

| bitstream | boards | local sets |
|---|---|---|
| `NamcoS2` | standard: sprites (A) + ROZ (A); **Final Lap / Four Trax: sprites (A, FL variant) + C45 road, sharing the ROZ RAM**; C65 **and** C68 | 33 + 16 |
| `NamcoS2_MH` | Metal Hawk: sprites (A, MH layout) + C169 x2 | 2 |
| `NamcoS2_NB` | C355 sprites + C45 road + C169, each enabled per set | 10 |

The `.mra` selects the board through a mode byte in `<switches>`, which
MS1BCD proved (MS1-44: fan-out and timing; MS1-53: the core waits for the
switches). Final Lap and Four Trax (sprites A + C45) are in `NamcoS2`, above.

### 2.5 The main board — `ns2_main.sv`

- Two fx68k, each with its own private map and C148.
  - The C148 model is MAME's register semantics: level per source,
    acknowledge per source, the master's reset outputs, and the watchdog
    (ignored).
  - The IACK returns vector 24 + level with DTACK (GN-10).
- The shared bus arbitrates the two 68000s onto the shared devices. C148 bus
  arbitration exists on the board; the core grants one CPU per bus cycle,
  round robin. Its effect on timing is measured (Q8).
- The key custom is table-driven per set (constants and the two handshakes)
  plus the LFSR of D5. Its index comes from the `.mra`.
- EEPROM: 8 KB BRAM. The ready status on `1E0000` bit 1 is always ready,
  per MAME; Q10 checks the real write cycle time. It loads and saves through
  MiSTer NVRAM (D6).
- The DPRAM is 2 KB and true dual port: the 68000 side (low byte) and the
  6809/MCU side.
- Program ROMs and data ROM come through `ns2_rom_hw` caches. MS1-50 applies:
  the caches get the region offset, not the raw bus address.

### 2.6 Sound — `ns2_sound.sv`

- **6809:** `mc6809is` with GN-4's power-up latch fix. The IRQ source (MAME's
  120 Hz periodic) is Q5; FIRQ comes from the C140.
- **YM2151:** `jt51`, vendored as in MS1BCD, with its three lessons:
  - MS1-29: `write` is sampled on `cen`;
  - MS1-61: never freeze `cen` for a replay;
  - MS1-62: the register shadow is captured at the write edge.
- **C140: `ns2_c140.sv`, new.** A port of MAME's `sound/c140.cpp`, verified
  sample-exact against it:
  - a C++ oracle built from `~/mame/src/devices/sound/c140.cpp`, as
    GingaNin's ymfm harness;
  - NA-1's `na1_c219.sv` as a design cross-check.
  - Voice ROM addressing follows `c140_rom_r` (the MD0-MD11 nibble wiring
    from the schematics).
- **Mix:** MAME's route gains are per machine config: base 0.75 / 0.80,
  base2 1.0, base3 0.45 / 1.0, Metal Hawk 1.0. They come from the mode byte,
  and levels are measured against MAME's WAV (GN-5's method).

### 2.7 I/O MCU — `ns2_io.sv` (D2, recommended A)

- **A (recommended):** the real MCUs.
  - **C65:** `jt6805` extended to the HD63705 (16-bit address space, NMI,
    the HD6305 extra instructions, the timer). Proven instruction by
    instruction against MAME's `m6805` HD63705 core on the C65 firmware
    (a unit harness, as the siblings' MCU proofs).
  - **C68:** a 65C02 core (candidates: T65 from the MiSTer tree, jtframe's
    `mc6502`) extended to the Mitsubishi 740 set (bit ops `SEB`/`CLB`/`BBS`/
    `BBC`, `LDM`, `COM`, `RRF`, `TST`, the T flag, `MUL`/`DIV` if used). A
    MAME `m740` trace decides which extensions the C68 firmware executes;
    only those are built.
  - Needs B1's device zips.
- **B:** a high-level model: an FSM writing the inputs, DIPs and analog
  values into the DPRAM locations the firmware uses, learned from MAME DPRAM
  traces. No device ROMs and no CPU cores, but it substitutes behaviour. Every
  game's protocol must be proven, and the coin, credit and service logic
  moves into our model. Kept as a fallback per game if A stalls.

The ADC, dials and ports follow `namco65.cpp` / `namco68.cpp`. The ADC
converts instantly in MAME; the real conversion time is Q11.

### 2.8 Video — `ns2_video.sv` and the board blocks

A **line renderer**, as every sibling: engines draw line L+2 into double
buffers and the mixer resolves priority per pixel. The M1 gate is MAME's
state-injected pictures.

- **C123 tilemaps (`ns2_c123.sv`):** six layers, 8x8 tiles at 8 bpp plus the
  mask, per-layer scroll, priority and colour. Scroll is latched at line
  start (GN-8's lesson) and flip is handled.
- **C116 (`ns2_c116.sv`):** the palette (R, G, B byte planes, 8,192 pens),
  the clip window, the POSIRQ line and the shadow pens (`0x2000` bank).
- **Sprites A (`ns2_spr_a.sv`):** 128 sprites from bank `gfx_ctrl[3:0]`,
  16/32 px with quadrant, x/y zoom (up to 63 px), flip, 8 bpp, priority 0-7,
  shadow pen. Rows are fetched in parallel (MP-14), with an overrun counter
  (MS1-60, GN-6). The zoom LUT ROM (`zoomlut`) is hooked up if MAME's TODO
  proves real (Q12).
- **ROZ A (`ns2_roz_a.sv`):** one 256x256-tile plane, 8.8 increments,
  12.4 start, wrap; the priority and colour bank come from gfx_ctrl.
- **C169 (`ns2_c169.sv`):** two planes of 16x16 tiles with a mask, per-plane
  control, and the board's tile callback.
- **C355 (`ns2_c355.sv`):** the Namco NB-1 sprite chip: its list format,
  zoom, the position registers and the buffer (Suzuka `set_buffer(1)`).
- **C45 (`ns2_c45.sv`):** the road tilemap and tile-gfx RAM, the CLUT PROM,
  `xoffset -72`.
- **Rotation:** MiSTer's `screen_rotate` for ROT90 (Assault, Metal Hawk,
  Phelios, Dirt Fox, Valkyrie, Dragon Saber, Cosmo Gang). ROT180 (Ordyne,
  Golly Ghost, Bubble Trouble) is a core flip. The scandoubler is disabled
  under rotation (NMK-28), and the rotation is written into the `.mra`
  (NMK-35).

### 2.9 Savestates

The engine is `savestate.sv` with the fixed-latency bus that GingaNin used.
The image goes to DDR3, in slots sized to the largest board: about 400-600 KB
per slot, so 1 MB slots.
- **Two `ss_m68k_park`** in GingaNin's form (the held RESUME read). The master
  parks first, then the slave, then the 6809, then the MCU, so no command or
  DPRAM handshake is in flight.
- **`ss_m6809_park`** (GingaNin) for the sound CPU.
- **The MCU park: new.** HD63705: NMI with a substituted vector, like
  `ss_m6809_park`. M37450: BRK or an NMI-equivalent with vector
  substitution. Or, under D2-B, just its FSM state.
- **YM2151:** register shadow and replay (MS1-61/62).
- **C140:** a state port (voice registers, positions, accumulators).
- **C148 x2, C116 registers, key custom state (LFSR, handshake flags),
  gfx_ctrl, sound bank, the EEPROM.**
- **The gate:** SS-13's three-save diff in attract and in play, with GN-10's
  harness rule that play inputs are re-applied after the load.

### 2.10 Feature parity with the siblings

- Pause, DIPs from the `.mra`, orientation (with the rotation framebuffer),
  flip, CRT Adjust, aspect, Scandoubler Fx.
- Autofire on the fire button (unlocked by `<switches>` byte 2, bit 7).
- Cheats from Pugsy's database: the per-game slots named from the first
  bitstream's parents.
- High scores: **native NVRAM** (D6). The games keep their own tables in the
  EEPROM, which a `.nvm` persists. The hiscore module is not needed. GN-11's
  NVM proof is repeated here: patch the `.nvm`, see the score.
- Savestates.
- Light guns (D8): MiSTer's analog/mouse gun input mapped onto the MCU's
  analog channels, with MAME's calibration (the default `.nv` carries it).
- Wheel and pedal: the analog stick or paddle onto the ADC.

### 2.11 Repository layout (as the siblings)

```
docs/          PLAN.md, known-issues.md (NS2-n), provenance.md
rtl/ns2/       ns2_core, ns2_main, ns2_c148, ns2_key, ns2_sound, ns2_c140, ns2_io,
               ns2_video, ns2_c123, ns2_c116, ns2_spr_a, ns2_roz_a, ns2_c169,
               ns2_c355, ns2_c45, ns2_rom_hw
rtl/savestate/ savestate, savestate_ui, ss_m68k_park, ss_m6809_park, ss_mcu_park
rtl/third_party/ fx68k, mc6809, jt51, jt6805 (+HD63705), 65C02/740, crt_adjust, hiscore
sim/oracle/    Lua capture (states, pictures, bus traces), MAME patches, the C140 oracle
sim/rtl/       video_state (M1), ns2_snd, ns2_c140, ns2_mcu, ns2_frames (M2), ns2_hw (M3)
tools/         romdata, .mra generator, model, torn replay, cheats/hiscore generators
releases/      .rbf and .mra (parents; clones under _alternatives/)
NamcoS2*.sv    Quartus tops, one per bitstream, sharing one emu body
```

### 2.12 No baked ROM data, and licences

Every ROM and MCU image comes through the download. Nothing ROM-derived is
committed or synthesised into a bitstream. The history scan before a push is
M6's gate.

Licences:
- GPL-3.0 for the core;
- jt51 and jt6805: GPL-3;
- fx68k: GPL-3;
- mc6809: BSD;
- T65: BSD-style, checked at vendoring;
- `na1_c219.sv` is consulted, not copied, unless its GPL-3.0-or-later terms
  are recorded in `provenance.md`.

---

## 3. Milestones, tasks and gates

### M0 — Foundation

- The repo, `deps.lock`, `.gitignore` (ROMs, traces, images), `LICENSE`,
  provenance.
- B1 resolved: the device zips in place, `-verifyroms` clean for 43 sets.
- **`tools/ns2_romdata.py`**: the ROM table from `-listxml` into one image
  layout per bitstream (Appendix D), with MAME's byte order checked against
  its memory (MS1-49).
- **Oracle** (`sim/oracle/`):
  - `ns2_capture.lua`: per-frame state (all video RAMs, control registers,
    palette, gfx_ctrl, C116 registers, DPRAM) and pictures;
  - the play scripts;
  - bus traces for the MCU (D2) and the sound CPU;
  - the MAME patch: a deterministic key-custom LFSR (D5) and per-chip route
    gains for isolation (GN-5's method);
  - a C++ C140 oracle.
- **Q-measurements** (section 6) from MAME, before RTL is judged.
- **The SDRAM probe** (D3): the pipelined controller against the model; the
  bandwidth gate.
- **`quartus_map` probe:** an empty top with the M10K arrays of Appendix F,
  to prove they infer (MS1-37, MS1Z-6, GN-9, SS-14).
- **The Python model:** a whole-frame renderer from captured state, exact
  against MAME's pictures on the standard board. It is the reference for M1.

**Gate:** the model exact on the attract of three standard games, and the
SDRAM probe passing its bandwidth gate.

### M1 — Video against MAME state

`sim/rtl/video_state`:
- inject a captured state, render, compare with MAME's picture. MS1Z-5 / MP-1
  / GN-2 decide the palette pairing;
- stall injection on every stream (MP-9);
- per board, in order: standard (tilemaps, C116, sprites A, ROZ A), then
  Metal Hawk (C169, MH sprites), then C355 (Steel Gunner 2), then C45
  (Suzuka), then Lucky & Wild.

**Gate:** 100 % of the sampled frames per board (at least 1,000 per board
across attract, play and flip), or each residue named as a MAME defect with
evidence.

**Status: passed (NS2-5, NS2-6).** The RTL covers every board and matches MAME
on 68,000+ frames and on flip through the model. For M3:
- **Metal Hawk and Lucky & Wild:** the C169's two layers make 576 random
  fetches a line, each a burst plus a mask byte, twice ROZ A's load.
- **NB boards:** the C355's busy lines reach about 600 sprite bursts (9.7
  M/s). D3's layout was sized for the standard board, and the MH and NB
  bitstreams need their own probe run (tile-row caches, a second copy).

### M2 — Whole board from reset (ROMs as arrays)

**Order (decided in M2):**
1. The C65 core first (done, NS2-7: MAME's trace and timing).
2. The whole board on the C65 sets (44 of 61).
3. The C68. Its cycles come from MAME's own instruction lists
   (`om6502.lst`, `om740.lst`: one cycle per bus call). Counting cycles from
   its bus trace does not work: MAME's taps miss the dummy `read_pc` cycles.
   - **Changed in M2:** jt65c02's microcode fixes one cycle count per
     opcode, but MAME's 6502 family adds conditional cycles (a page
     crossing, a taken branch).
   - So `tools/ns2_740gen.py` generates the core (`rtl/ns2_m740.sv`) from
     MAME's lists instead. Each bus call becomes a state, so every path takes
     MAME's cycles by construction, and all 512 table entries are covered
     (T mode is the table's second half).
   - Every C68 set runs the device's own `c68.bin`: the per-set
     `c68mcu:external` region is never mapped.

**Progress (step 2, Assault):**
- Each 68000's first 3,000,000 bus accesses match MAME's, data included
  (`sim/oracle/ns2_bustrace.lua`). The master's run to frame 69; the
  slave's start at its release in frame 55 and run to frame 121.
- A byte-wide device (C116, DPRAM, EEPROM, C148) reads 0x00 on the other
  lane, matching what MAME's `umask16` handlers return.
- The master's timing matches too: its clock is MAME's + 24 at every
  access over 1,500,000 accesses.
- The 6809's first 60,000 writes match, and so do all 65,817 of the MCU's
  DPRAM writes (to frame 1184). NS2-8 has the details.
- With MAME's CPUs interleaved finely, the master matches 8,000,000
  accesses and the C140 all 298,700 samples (14 s).
- The board's pictures, replayed from MAME's writes line by line: 675 of
  678 frames exact, and the rest are writes within a line's own fetch
  window (NS2-10).
- The C68 (Super World Stadium '92): all 3,000,000 cycles in its harness,
  and all 14,846 DPRAM writes on the board (NS2-9).

`sim/rtl/ns2_frames`:
- both 68000s, the 6809, the MCU (D2), the sound, the video; the ROMs as
  arrays;
- the CPU speeds calibrated by MAME state injection (MP-13) if caches or
  arbitration slow the 68000s.

**Gates:**
- boot to attract on every standard parent;
- pictures exact or explained by tearing (GN-7's replay tool);
- bus traces agree until an interrupt lands apart (MS1-22);
- sound within GN-5's tolerances; C140 sample-exact;
- the MCU's DPRAM writes identical to MAME's.

### M3 — Hardware path

`sim/rtl/ns2_hw`:
- the real download into SDRAM through the new controller;
- a copy check;
- a response checker on every stream (MP-11);
- zero overruns;
- measured latencies (MP-13: the harness is not the board);
- M2's pictures reproduced (GN-8's gate).

### M4 — Quartus and the board

- Per bitstream: `quartus_map` M10K check, a full compile, timing met
  (seed search if needed, as MS1Z and NMKBP964). `build.sh` refuses stale
  `.rbf`s.
- On the board (192.168.1.138):
  - deploy by md5;
  - diagnose a black screen with SS-15's method;
  - check the attract against MAME frames by screenshot;
  - HDMI audio;
  - check inputs with `mister_keys.py`.

### M5 — Feature parity

Savestates (the SS-13 gate in attract and play, then the board), NVRAM
(`.nvm` patch proof), cheats, autofire (GN-11's savestate-RAM method), pause,
DIPs, orientation and flip, CRT Adjust, light guns, analog controls, and the
clone sets.

### M6 — Release

`releases/` gets the `.rbf`s and `.mra`s. The history is scanned, the
branch is pushed to `kuzearcade/Arcade-NamcoSystem2_MiSTer`, and the core is
added to kuzecores. `db.json.zip` is verified by commit.

---

## 4. Lessons carried in, mapped onto this board

### 4.A ROMs, `.mra`, loading

- **Byte order:** the 68000 image's byte order is checked against MAME's
  memory (MS1-49), and so is the C140's nibble wiring.
- **Switches:** MiSTer never sends an empty `<switches>` (MS1-47); the core
  waits for them (MS1-53). The mode byte selects the board.
- **Naming:** `.nvm` files are named by description and `.CFG` files by
  setname (NMK-24); the `.dip` override covers the whole switches value.
- **Well-formed XML:** every `.mra` is parsed as XML before it is written (a
  `--` in a comment broke NMKBP964's).
- **ROM extractor:** a `BAD_DUMP` part must not be silently dropped (MS1-3).
- **Clone paths:** clones go under `_alternatives/_<Parent>/`.
- **Missing parents:** `sgunnerj` needs its parent; a set with missing parts
  is generated only when complete.

### 4.B SDRAM, caches, buses

- Held requests need a "seen low once" arbiter (SS-12 #3). Withdrawn requests
  (sprite restarts) are discarded answers (GN-8's `romport`).
- The ROM path can starve CPUs (SS-12). The CPU speed is set by measurement
  (MP-6, MP-13).
- The loader's reset is power-on only (SS-15).
- The caches get region offsets (MS1-50).
- Harness latency is not board latency (MP-13): M3 measures the board path.

### 4.C Quartus

- **M10K inference:**
  - byte-lane read-modify-write does not infer (MS1Z-6);
  - multi-read arrays do not infer (GN-9);
  - clear-on-read second ports do not infer (GN-9);
  - `quartus_map` catches drivers Verilator ignores (MS1-38).
- **Timing:** mode bytes are timed as data (MS1-44); multicycle islands
  (MS1-43); seeds.
- **The appended `.qsf` block** is trimmed before every commit.

### 4.D Video

- **Line renderer versus MAME's whole frame:** MP-4, MS1Z-12, GN-7. Here MAME
  partially updates at POSIRQ (fact 7), so the torn-replay tool is extended
  with POSIRQ slices.
- **RGB latency:** position is delayed, not pixels (MS1-59).
- **Overruns:** the sprite pass must not overrun (MS1-60); parked sprites
  must not swallow lines (GN-6); rows are fetched in parallel (MP-14).
- **Scroll** is latched at line start (GN-8).
- **Palette pairing** in MAME's pictures: MS1Z-5, MP-1, GN-2.
- **The unwritten-palette default** (GN-1): checked for the C116.
- **Flip** is rot180 of the frame (MS1-13), composed with the OSD flip.

### 4.E Audio

- **YM2151 (jt51):** MS1-29, MS1-61 and MS1-62.
- **Clock dividers:** a fractional accumulator one bit too narrow (MS1-28).
- **Levels:** measured against MAME by isolating each chip. MS1Z-13's and
  GN-5's calibrations are recorded with their open causes.

### 4.F Simulation harnesses

- The sim Makefiles depend on every RTL file (MS1-58).
- `make lint` fails on undriven signals.
- A green gate can mean nothing was exercised (MS1-18): each gate reports its
  coverage.
- Lua pitfalls: taps are garbage-collected (MS1-10), `screen:pixels()`
  returns three values (MS1-9), there is no `screen:vpos()` (MS1Z-4), and a
  relative `-rompath` breaks (MS1-26).
- MAME persists forced DIPs into `cfg/` (MS1-25).
- **Savestate harness:** GN-10's input re-application after a load; DTACK
  vectored IACK.

### 4.G Board and process

- **Deploying:** deploy by md5, taking screenshots with a gap between them
  (GN-10's board test). Savestate keys use chords with a 0.6 s hold.
- **NVM proofs:** patch only bytes inside a record (GN-11).
- **Shell hygiene:** `pkill`/`pgrep` must not match their own command line;
  use `tail -n`, not `tail -2`.
- **Commits:** nothing ROM-derived, milestone commits only, pushes only when
  asked.
- **kuzecores:** verify `db.json.zip` by commit (the raw CDN caches).

### 4.H Working method

- Findings are numbered and state their evidence and status (closed or open).
- A MAME defect is recorded, never copied or silently "fixed".
- Every decision in section 7 is re-examined by its measurement.

---

## 5. Risk register

| risk | likelihood | impact | plan |
|---|---|---|---|
| ROZ bandwidth: a random read every 217 ns | **high** | ROZ games unplayable | D3-A pipelined SDRAM, probed in M0; fallback line tile cache (D3-B) |
| ALMs: two fx68k + 6809 + MCU + jt51 + C140 + six tilemaps + zoomed sprites + ROZ | medium-high | does not fit | D1 split; the `quartus_map` probe per bitstream in M0-M4 |
| M10K: work RAMs + ROZ RAM + C45 RAM + C355 RAM | high on `NamcoS2_NB` | does not fit | Appendix F; work RAM to SDRAM with cache; Q2 sizes the slave RAM |
| Two 68000s through caches at 12.288 MHz run slow | medium | gameplay slowdown | caches sized by trace; MP-13 calibration |
| MCU cores: HD63705 and 740 extensions | medium | no inputs | unit harnesses against MAME traces; D2-B fallback per game |
| B1: device zips unavailable | -- | MAME cannot run the sets, so there is no oracle and no MCU | please supply them; nothing can be measured without them |
| Key custom beyond MAME's table | medium | a game locks | trace every key read in MAME; any `rand()` read becomes the LFSR (D5) |
| C140 formats | low | wrong samples | sample-exact harness against MAME's C140 |
| MAME defects (fact 7) | known | "differences" that are correct | recorded as NS2 findings |
| Light-gun calibration and feel | medium | guns off target | MAME's calibration via the default `.nv`; board test with a mouse |
| Serial link (C139) | -- | no linked play | stub; out of scope |
| Diorama lamps (Golly Ghost, Bubble Trouble) | -- | no lamps | the games play without; out of scope |

## 6. Open questions — each settled by a measurement

| Q | question | how |
|---|---|---|
| Q1 | Which 68000 instructions and bus patterns stress the shared bus (arbitration cost)? | MAME bus traces of both CPUs, attract and play |
| Q2 | Slave RAM: which range is ever touched (MAME maps 256 KB)? | MAME write taps over 10 minutes of play per game |
| Q3 | Worst-case per-line load: sprites per line, ROZ pixels, tile fetches | MAME state per frame, the model counting per line (MP-3's method) |
| Q4 | Does any game rely on the key custom beyond MAME's table? | taps on key reads: offset and returned value per game |
| Q5 | Sound CPU IRQ: MAME's 120 Hz periodic, or a board source? | 6809 handler cadence against the YM2151 and C140 writes; the C121 glue |
| Q6 | MCU interrupt timing (MAME: line 200, "exact timings unknown") | Assault Plus's mode select as the probe; the DPRAM handshake timing |
| Q7 | Does Assault Plus work at the board's real rates? | M2 with real MCU clocks; no quantum exists in RTL |
| Q8 | Bus arbitration order and cost between master and slave | Q1's traces; M2 frame agreement |
| Q9 | Audio ROM: 128 or 256 KB per set; BRAM or cached | the ROM table |
| Q10 | EEPROM write timing (MAME: always ready) | the game's EEPROM routine against the ready bit |
| Q11 | ADC conversion time (MAME: instant) | the firmware's polling loop |
| Q12 | The sprite zoom LUT: needed, or is MAME's arithmetic exact? | the model against MAME and, if possible, the LUT's content |
| Q13 | The POSIRQ off-by-one (MAME's Burning Force TODO) | captures around the split; the board's C116 register semantics |

## 7. Decisions for you before M0

| id | decision | A (recommended) | alternatives |
|---|---|---|---|
| **D1** | Bitstreams | Three from one tree: `NamcoS2` (standard, 33 sets), `NamcoS2_MH` (2), `NamcoS2_NB` (C355 / C45 / C169, 9) | B: one bitstream with every board (does not fit); C: the standard board only, first and alone |
| **D2** | I/O MCU | Real MCUs: HD63705 (extended jt6805) and M37450 (65C02 + 740 extensions); needs B1 | B: a high-level DPRAM model learned from MAME traces |
| **D3** | Graphics memory | Pipelined, bank-interleaved SDRAM controller (jtframe_sdram64 or extended `sdram.sv`), gated by an M0 bandwidth probe | B: a per-line ROZ tile cache; C: DDR3 (rejected for random reads) |
| **D4** | Clocks | 49.152 MHz `clk_sys` (every clock exact but the YM2151); SDRAM at 98.304 MHz | B: 48 MHz with fractional enables, as the siblings |
| **D5** | Key-custom randomness | A 16-bit LFSR in the core and in a MAME oracle patch, so every set is comparable | B: no patch; the random-reading games are compared only until their first random read |
| **D6** | High scores | Native EEPROM NVRAM (`.nvm`), with default `.nv` files through the `.mra` | B: also hiscore.dat (redundant here) |
| **D7** | Scope | All 61 local game sets (Final Lap, Four Trax, `sgunner` and `sgunnerj` included) | B: parents only first |
| **D8** | Guns and analog | MiSTer's analog/mouse input onto the MCU's ADC for guns, wheels and pedals | B: exclude the gun and driving games |

**Blocker B1:** `namcoc65.zip`, `namcoc68.zip` (and `sgunner.zip`) into
`~/Arcade-NamcoSystem2_MiSTer/mame_roms`.

## 8. Day one (after approval and B1)

1. `git init`, `deps.lock`, `.gitignore`, `LICENSE`, the provenance skeleton.
2. `-verifyroms` on all sets; `-listxml` into the ROM table; the image
   layouts.
3. The MAME oracle patch (key LFSR, route gains), rebuilt; `ns2_capture.lua`
   on Assault, Rolling Thunder 2 and Metal Hawk.
4. The SDRAM bandwidth probe (D3).
5. The `quartus_map` M10K probe (Appendix F).

---

## Appendix A — OSD string (draft, per bitstream)

```
NamcoS2;SS3E000000:100000;
Aspect ratio, Scandoubler Fx, Orientation (H0), Flip screen, CRT Adjust (P3),
P1/P2 Autofire (h1), DIP, Pause,
P1 "Scores": Save NVRAM, Reset NVRAM,
P2 "Cheats": slots named per bitstream,
P4 "Savestates": Slot, Save, Load (Alt+F1-F4 / F1-F4),
Gun: Crosshair, Gun input (mouse / analog),
J1,Button 1,Button 2,Button 3,Start,Coin,Service
```

## Appendix B — Memory maps in the core

As 1.2-1.4, per bitstream. The mode byte gates the graphics-board decode.

## Appendix C — Savestate image (draft, 16-bit words)

| contents | size (bytes) |
|---|---|
| master RAM | 64 KB |
| slave RAM | 64-256 KB (Q2) |
| tilemap RAM + control | 64 KB + 64 B |
| palette + C116 registers | 24 KB + 32 B |
| sprite RAM (A: 16 KB; C355: 82 KB) + gfx_ctrl | ≤ 82 KB |
| ROZ RAM (A: 128 KB; C169: 64 KB) + control | ≤ 128 KB |
| C45 RAM | 128 KB (Suzuka, L&W) |
| DPRAM, sound RAM, MCU RAM, EEPROM | 2 + 8 + 0.5 + 8 KB |
| C148 x2, key custom, sound bank, YM2151 shadow, C140 state, park frames | < 2 KB |

About 400-600 KB, so 1 MB slots at `0x3E000000`.

## Appendix D — `.mra` ROM layout (index 0, one image per set)

| offset | region |
|---|---|
| 0x0000000 | master program (256 KB) |
| 0x0040000 | slave program (256 KB) |
| 0x0080000 | audio program (256 KB) |
| 0x00C0000 | MCU external EPROM (32 KB) |
| 0x00C8000 | MCU internal ROM (8 KB C65 / 32 KB C68, from the device zip) |
| 0x00D0000 | C45 CLUT (256 B), padding |
| 0x0100000 | data ROM (2 MB) |
| 0x0300000 | C140 voices (2 MB) |
| 0x0500000 | tile mask (512 KB) |
| 0x0580000 | ROZ mask (512 KB, C169) |
| 0x0600000 | tiles (4 MB) |
| 0x0A00000 | sprites (4 MB) |
| 0x0E00000 | ROZ tiles (4 MB) |
| 0x1200000 | end (18 MB) |

Plus `<nvram index="4" size="8192">` with the default `.nv` where MAME has
one, and the mode byte and key-custom index in `<switches>`.

## Appendix E — Vendored sources and pins (to be pinned in `deps.lock`)

| source | from | licence |
|---|---|---|
| fx68k | Arcade-GingaNin_MiSTer (its pin) | GPL-3 |
| mc6809is (GN-4 fix) | Arcade-GingaNin_MiSTer | BSD |
| jt51 | Arcade-JalecoMS1BCD_MiSTer's pin (jotego/jt51) | GPL-3 |
| jt6805 (+HD63705) | jotego/jtcores `modules/jtframe/hdl/cpu` | GPL-3 |
| 65C02 for the 740 | T65 (MiSTer tree) or jtframe `mc6502` | per source |
| jtframe_sdram64 (D3-A candidate) | jotego/jtcores | GPL-3 |
| savestate, savestate_ui, ss_m68k_park, ss_m6809_park | Arcade-GingaNin_MiSTer | GPL-3 (ours) |
| sdram.sv, sdram_arb, crt_chain, cheats, video_retime, hiscore, crt_adjust, sys/ | siblings | as recorded there |

## Appendix F — M10K budget (measured in M0: NS2-4)

553 blocks of 10 Kbit. `sim/quartus/m10k_probe` fits the standard board's
arrays at their real shapes and port use, and reports each one's count.
Everything outside the core comes from the siblings' fitted builds.

| array | port use | M10K (fitted) |
|---|---|---|
| master RAM 64 KB | CPU | 64 |
| slave RAM 64 KB (Q2: 64 KB mirrored, NS2-4) | CPU | 64 |
| C123 tilemap RAM 64 KB (all of it used after boot, NS2-4) | CPU + video | 64 |
| ROZ RAM 128 KB (the C45 road RAM on Final Lap) | CPU + video | 128 |
| sprite RAM 16 KB | CPU + video | 16 |
| palette, 3 x 8 KB | CPU + video | 24 |
| DPRAM 2 KB | two sides | 2 |
| sound RAM 8 KB | 6809 | 8 |
| EEPROM 8 KB | CPU + NVRAM ioctl | 8 |
| tile class table 64K x 2 (D3) | load + video | 16 |
| tile-row cache, mask cache, their tags (D3) | fill + video | 5 |
| sprite line buffers, double | | 2 |
| **the probe's total** | | **401** |
| two fx68k (microcode ROMs), jt51 | | 12 + 7 |
| outside the core: sys/ 56; crt_chain 28, video_mixer 14, hiscore 6, video_retime 3 (GingaNin and MS1BCD fits) | | 107 |
| **subtotal** | | **527** |

That leaves **26 blocks** for everything else:
- the program caches: master, slave, audio, data ROM;
- the MCU's ROMs;
- the tile and ROZ line work;
- the C140.

So:
- **The MCU's ROMs go to SDRAM behind small caches.** That is the 32 KB
  external EPROM and the C68's 32 KB internal ROM, 64 blocks in BRAM. The
  C65 runs at 2 MHz and the C68 at 8 MHz, so a miss costs less than a cycle
  of theirs.
- The CPU program caches are the siblings' `rom_cache_n` (MS1BCD), at 1-2
  blocks each.
- If the fit still fails, the next lever is the master's work RAM behind a
  cache in SDRAM (-64 + the cache). Its cost is wait states on misses, which
  M2's frame agreement would have to show harmless.

The NB bitstreams swap:
- ROZ RAM and sprite RAM (144) for C355 (82), C169 (64) and C45 (128),
  which is +130;
- so both work RAMs move to SDRAM behind caches (-128) there, as planned,
  and the NB fit is decided at M5 with the same probe.
