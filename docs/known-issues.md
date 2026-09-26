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

The frames that are not exact:
- `assault` frames 1-20 are MAME's boot screen before its first draw (all
  0x00ffff). This is a MAME artifact.
- `assault` 2022 (167 pixels of line 0) and `finehour` 3580 (one sprite)
  were VRAM rewrites between MAME's bands. NS2-5 logs them, and both are
  exact since.

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

## NS2-5 — The other boards, and the VRAM MAME draws a band with (closed, measured)

The model and M1's RTL cover every board. Each item below was measured
against MAME's pictures.

**Metal Hawk** (`metlhawk_state`):
- **Sprites:** 8 words a sprite, and no bank.
  - `scalex` always divides by 0x20, so a 16-wide sprite is (sizex + 1) / 2
    pixels.
  - A smaller 32 x 32 sprite moves by (32 - w) / 8 and (32 - h) / 12.
  - The rot90 bit selects an xy-swapped decode. The core keeps a transposed
    copy of the sprite ROM (the testbench builds it).
- **C169:** two layers of 16 x 16 tiles on a 4096 x 4096 map. Layer 1 takes
  per-line parameters from video RAM when control word 0 is 0x8000 (not
  seen in attract).
- **Priorities** run 0..15: the C123 planes at 2p, then the C169 layers 1
  and 0, then 4-bit sprites.

**Final Lap:**
- The `finallap` config (5 sets) uses `namcos2_sprite_finallap_device`:
  the sprite number is w1[12:2] and the 32/16 select is w1 bit 13.
  - Before this, a Final Lap sprite drew a 32 x 32 tile where MAME drew a
    16 x 16 quarter: 41 frames with 5-6 pixels each.
- Its sprite priority is 4 bits (`metlhawk_state`'s callback).
- `finalap2` and `finalap3` use `TilemapCB_finalap2`.
- The games use 3 KB at most of the 64 KB sprite window.

**The C45 road** (Final Lap, Suzuka, Lucky & Wild):
- a 64 x 512 map of 16 x 16 2 bpp tiles in RAM;
- per-line priority, screen x, source line and zoom;
- a 256-byte CLUT;
- no transparent pen on System 2.

**The C355** (Steel Gunner, Suzuka, Lucky & Wild):
- **Buffering:** Suzuka and Lucky & Wild build the list at vblank
  (`set_buffer(1)`), so the picture shows state F-1's sprites. That made
  Suzuka's frames exact.
- **The shadow pen** sets 0x800 whatever the colour (sgunner's mix).
- **Steel Gunner** uses priorities 0..7.
- **The split has a closed form.** MAME splits a sprite of V pixels into n
  rows by repeated division, which gives q = V // n, rem = V % n: the first
  n - rem rows are q high, the last rem rows q + 1. Row r's zoom is
  q * 4096 + (min(rem, n-r) * 4096) // (n-r), a 16 x 16 table. Columns work
  the same way.
  - `tools/ns2_c355hw.py` computes this line by line, as the RTL does, and
    equals MAME's frame algorithm on every sampled frame.
- **Line load:** busy lines are heavy. Lucky & Wild's line 131 of frame 1296
  has 48 sprites, 302 tile columns and 3,626 pixels (12 x overdraw).
  - The RTL's C355 walks a column a clock, fetches through an 8-deep job
    queue, and draws two pixels a clock (the sprite line buffer is split by
    x & 1).
  - Its SDRAM load, about 600 bursts on that line (9.7 M/s), is M3's
    problem for the NB bitstream.

**The VRAM MAME draws a band with.** MAME draws a band at its POSIRQ line
with the VRAM of that moment, but the model took every band's VRAM from state
F. Games rewrite text and sprite banks mid-frame, which caused:
- `finehour` 3580;
- `finallap` 811;
- 26 `luckywld` frames;
- `suzuka8h` 39;
- `assault` 2022.

The capture now logs every write to the tilemap RAM and the sprite RAM with
its line (`vram.txt`). State F-1 plus frame F's logged writes equals state F,
word for word, on every frame checked. The model and the testbench rebuild
each band's VRAM from it, and all five cases are exact.

**Flip.** The games set the C123's flip from their service menus, so attract
and play almost never show it (1 frame in all the captures). The "Video
Display" DIP is not it. `tools/ns2_flipref.py` forces the flip into 200
states per board, and in every band's registers, and writes the model's
pictures. The model's flip matches MAME on sws93's flipped frame. The RTL
equals those pictures on all eight boards.

**The RTL's bugs the comparisons found**, as patterns to check in any new
RTL:
- a `{}` concatenation is unsigned, so it turned a signed window test
  unsigned (C355);
- a product inside a concatenation is self-determined: `rr * nc` at 5 bits
  wrapped (C355), and `k * 13'd4096` at 13 bits overflowed (C355);
- a saturated 28-bit value plus a step wrapped (C45);
- a state encoded as `F_ADDR + 7` overflowed a 3-bit state register (C123);
- two line-buffer writers, or two drivers of one RAM address, where a mux
  belongs.

**Line time.** The C123 now fetches a plane's slots while drawing the plane
before it (two slot banks). With stall injection, the busiest line on any
board takes about 2,000 of its 3,072 clocks.

## NS2-6 — M1's gate: the video RTL against MAME, every board (closed, measured)

`sim/rtl/video_state` checks the RTL against MAME's pictures:
- captured state is injected, with state F+1's palette and MAME's bands;
- each band's registers and VRAM are rebuilt (NS2-2, NS2-5);
- every ROM stream is served with random stalls (up to 24 clocks, a quarter
  of requests refused).

| board | sets and captures | frames | exact | busiest line |
|---|---|---|---|---|
| standard | assault, burnforc, dsaber, phelios, rthun2, sws93 attract (3,599 each); finehour attract with VRAM log | 25,193 | all but assault's 21 | 2,783 |
| standard | play: assault, burnforc, dsaber, finehour, phelios, rthun2, sws93 (2,398 each) | 16,786 | all | 2,435 |
| Final Lap | finallap (VRAM log), finalap2, finalap3 attract | 10,797 | all | 2,010 |
| Final Lap | fourtrax, VRAM log | 1,999 | all | 2,010 |
| Metal Hawk | attract and play | 5,997 | all | 2,360 |
| Steel Gunner | sgunner2 attract | 3,599 | all | 2,010 |
| Suzuka | suzuka8h attract | 3,599 | all but frame 39 | 2,013 |
| Lucky & Wild | luckywld, VRAM log | 3,599 | all | 2,254 |
| flip, forced | 200 per board, eight sets, against the model | 1,600 | all | |

The residues:
- **assault 1-20** are MAME's boot screen before its first draw.
- **assault 2022, suzuka8h 39, and fourtrax's 30** are on captures taken
  before the VRAM log. With the log, all are exact: model and RTL on
  fourtrax (1,999/1,999); the model on the other two frames.

No line overran. The busiest line on any board, with stalls, took 2,783 of
its 3,072 clocks.

## NS2-7 — The C65: jt6805 widened to MAME's HD63705Z0 (closed, measured)

`rtl/ns2_hd63705*.v` is jt6805 changed to match MAME's HD63705Z0
(`hd6305.cpp`):
- 16-bit addresses;
- the stack at 0x100-0x17f;
- vectors at 0x1fe0 + 2 x a 4-bit number: reset 0x1ffe, SWI 0x1ffc, IRQ1
  0x1ff8, A/D 0x1fea;
- IRQ1 ahead of the A/D interrupt.

MAME does not implement the chip's own peripherals. The C65's ports, DIPs,
dials, A/D and DPRAM are the board's handlers (`namco65.cpp`). The firmware
uses only the plain 6805 set (Assault's C65: no MUL, no STOP or WAIT).

`sim/rtl/mcu` checks the core against MAME's own traces
(`sim/oracle/ns2_mcutrace.lua`: bus accesses, instructions, interrupts).
- I/O reads return MAME's values in order.
- Interrupts and resets are applied where MAME's stream shows them.
- Every access is compared.

**Assault, 120 frames from power-on:** all 444,147 accesses match
(161,949 instructions, every IRQ1 and A/D interrupt, one reset by the
68000). The core also makes 1,061 reads MAME's does not, all harmless on
RAM or ROM:
- the read before a read-modify-write (CLR, BSET);
- the opcode fetch jt6805 makes before it checks for an interrupt, which it
  then discards (it pushes the right PC).

**The cycles.** The microcode first kept the 68705's counts. 39 opcodes
differ from MAME's HD63705 table:
- inherent A/X operations take 2 cycles, not 3;
- stores take one fewer;
- JSR takes one more;
- CLC, SEC and NOP take 1;
- SWI takes 11.

`rtl/63705.yaml` is jt6805's YAML with MAME's counts. JSR ext, JSR idx and
SWI need more steps than a 16-step microcode entry allows, so they call a
4-step idle procedure (at the unused opcode 0x31) and the generator pads the
rest. The generator then reports every opcode cycle-exact.

**The check.** MAME raises IRQ1 at line 200 every frame, so the core's
clocks between two IRQ1s should be one frame: 8,448 E cycles, 33,792
clocks. Measured over 63 frames of Assault: mean 33,792.6, range 33,780 to
33,820 (the instruction MAME was in when line 200 came).

## NS2-8 — M2: the whole board against MAME's bus traces (open: the C140, the C68)

`sim/rtl/ns2_frames` runs the board from power-on and compares each CPU with
MAME's trace (`sim/oracle/ns2_bustrace.lua`). With `MP_TIME=1` the trace
has MAME's clock for every access, so timing is compared too.

**Assault, the results:**
- **Master 68000:** its first 3,000,000 accesses match MAME's, data
  included. Over the first 1,500,000 its clock is MAME's + 24 at every
  access, with no drift. The 24 is fx68k's reset sequence.
- **Slave 68000:** its first 3,000,000 accesses match, from its release in
  frame 55.
- **6809:** its first 60,000 writes match (to frame 245).
- **MCU:** all of its 65,817 DPRAM writes match (to frame 1184), including
  the boot script's Start press.

- **Master, with MAME's CPUs interleaved finely** (`NS2_QUANTUM_HZ=12288000`,
  below): its first 8,000,000 accesses match (to frame 169), at MAME's
  clock + 24 throughout.
- **C140 on the board:** the same run's 298,700 samples (14 s, the first
  sounds included) equal MAME's.
- **C140 alone** (`sim/rtl/ns2_c140`): replaying MAME's 6809 writes at
  MAME's clocks, all 419,849 samples (19.7 s) equal MAME's mixer sums
  (`NS2_C140_DUMP`). That includes the voices, compressed and linear, loops
  and ends.

**What it took:**
- **The unused byte lane reads 0.** A byte device (C116, DPRAM, EEPROM,
  C148) returns 0x00 on the other lane, as MAME's `umask16` handlers do. It
  was 0xff before.
- **No wait states.** MAME's 68000 never waits, and three RTL paths cost
  one clock (4 clocks of `clk`) per access:
  - a local device's DTACK waited for a data strobe, which a write asserts
    a state after AS. It now counts from AS: fx68k takes DTACK up to 4
    clocks after AS without a wait state, and 5 costs one;
  - the arbiter's grant took a clock of its own; it now selects the device
    in the same clock;
  - a shared write waited for its request to finish. It now gets DTACK from
    AS, and its request goes out with the data strobes and completes long
    before the next bus cycle.
- **MAME's screen starts at the top of VBLANK.** Time 0 is vpos 224, so
  the video's counter resets to 224. The 68000s mask their interrupts
  while they boot, so the master's trace could not show this. The MCU's
  IRQ1 did.
- **MAME's IRQ1 input is held (`HOLD_LINE`).** The HD63705 core latches
  IRQ1 only when that input changes, and the input stays held until the
  core enters any interrupt. The MCU's reset clears neither. So the first
  line 200 after the master releases the MCU is lost unless an interrupt
  came first. `ns2_c65` models the held input; only the board's reset
  clears it.

**Where the MCU parts from MAME.** From its first opcode, every
instruction takes MAME's time. It starts 11 cycles later than MAME
stamps it: jt6805's reset takes 8 cycles to fetch the vector, and MAME
stamps its first instructions 48 clocks before the release, because a
CPU resumed mid-timeslice runs from the slice's base. So an interrupt can
land one instruction apart. That is the gate's allowance: bus traces
agree until an interrupt lands apart (MS1-22). The MCU's DPRAM writes are
the contract with the 68000s, and they all match.

**The C140's timing, as MAME's stream.** A MAME stream update at time t
computes the samples whose clock edge is at or before t. So a register
write never reaches a sample whose edge has passed.
- The RTL computes each sample at its edge, and the voice-register writes
  wait in a queue while it runs. The CPU's own view (register reads, the
  key status) changes at once.
- MAME's C140 clock is the XTAL's 21333.33 Hz truncated to 21333 Hz, so
  its edges fall every 2304.03 clocks. `MAME_RATE = 1` (the testbenches)
  places the edges as MAME does; the board uses the exact 2304.

**MAME's quantum is the oracle's error.** With the driver's quantum MAME
runs each CPU for a slice before the next. At access 3,399,559 the master
polls 0x40fffe for the slave's reply to a handshake. The slave writes it
at 60,481,040, before the master's read (about 60,481,100), but MAME
runs the master's whole slice first, so the master reads the old value.
The board is concurrent, as the RTL is. From that point MAME's
timeline runs about 570 clocks behind: the sound CPU's release and every
sound follow.
- The oracle patch's `NS2_QUANTUM_HZ=n` (MAME's `add_quantum`) interleaves
  the CPUs every 1/n s; one 68000 clock (12288000) resolves the handshake
  as the RTL does.
- It costs little (Assault's 14 s: 5 s), so the M2 traces use it.
- The C148's ext input: MAME leaves it unconnected and reads 7 (was 1).

**The boot script's Start press.** `ns2_boot.lua` sets the button in
frames 300-305, but MAME's ports read it from the next frame's input
update. The testbench presses it from frame 301 (`ports.txt` records the
port, mask and frame).

## NS2-9 — The C68: MAME's 740 core, generated (closed for the core, measured)

The C68 is a Mitsubishi M37450 (the 740 family). Every C68 set runs the
same firmware, the device's `c68.bin` at 0x8000–0xffff; MAME never maps
the per-set `c68mcu:external` region. Super World Stadium '92 was traced:
the C68 uses 69 instruction forms. They include the 740's `ldm`,
`seb`/`clb`, `bra`, `inc a`, decimal mode, and T mode (`set`, then `ldt`,
`ort`: LDA and ORA on the byte at X).

**Why not jt65c02.** Its microcode fixes one cycle count per opcode. MAME's
6502 family adds cycles on a page crossing and a taken branch, and the
740's own instructions (BBS/BBC, SEB/CLB, LDM, COM, TST, RRF, the T-mode
ALU forms) are not the 65C02's.

**The generator.** `tools/ns2_740gen.py` turns MAME's own lists into
`rtl/ns2_m740.sv`:
- `dm740.lst` gives 512 entries; T mode is the second half.
- The instruction bodies are `om740.lst` over `om6502.lst`.
- Each bus call is one state, as in MAME's `m6502make.py`. The statements
  between two calls run in C's order within the cycle: blocking
  assignments, with expressions as C's 32-bit signed ints, truncated to
  the variable's width.
- The helpers (`do_adc`, `set_nz`, the T-mode `do_adct`, ...) are hand
  transcriptions of `m6502.cpp` and `m740.cpp`.
- Statements after a `prefetch()` run after its interrupt check:
  `cli`, `sei` and `plp` change I there, the 6502's one-instruction delay.
- 919 states cover the 233 bodies.

**The peripherals** (`rtl/ns2_c68.sv`), as MAME's `m3745x.cpp`:
- ports P3–P6 with their direction registers; P3 bit 7 selects the player
  half P5 reads;
- the 50-cycle A/D;
- the two request/enable register pairs, mapped to m740 lines, with the
  lowest line's vector;
- the VBL acknowledge at 0x6000.

**The check** (`sim/rtl/c68`). MAME's taps see every M37450 cycle,
opcode fetches included, each stamped at its start, so the harness compares
every cycle: address, direction, data. The DPRAM reads return MAME's values
(the 68000s are not in the harness).
- **Super World Stadium '92:** all 3,000,000 cycles match (89 frames from
  the release, every VBL and A/D interrupt).

**MAME's timing.**
- MAME checks for an interrupt at the end of an opcode fetch cycle, and a
  bus access happens at its cycle's start. The A/D therefore completes 50
  cycles after the start of its control write's cycle.
- MAME's scheduler lets the MCU run up to a cycle past an event. Its VBL
  entries land 0, -24, +24 or +48 clocks from line 200 (26, 24, 26 and 13
  of 89 frames). The harness moves each frame's line 200 to MAME's entry
  when one lies within two cycles. On the board, a VBL can land one
  instruction apart from MAME's: MS1-22's allowance.
