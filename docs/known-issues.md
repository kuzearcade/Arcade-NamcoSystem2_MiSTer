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
- **On the board:** all of the C68's 14,846 DPRAM writes match MAME's, to
  frame 400, the Start press included.
- **A simulation race, fixed.** The generated core first set its bus outputs
  with blocking assignments in its clocked block. The peripherals, clocked by
  the same edge, could then see the next cycle's address and data, depending
  on the simulator's order. The harness happened to work; the board lost
  pushes. The core now computes into internal variables and registers its
  outputs.

**MAME's timing.**
- MAME checks for an interrupt at the end of an opcode fetch cycle, and a
  bus access happens at its cycle's start. The A/D therefore completes 50
  cycles after the start of its control write's cycle.
- MAME's scheduler lets the MCU run up to a cycle past an event. Its VBL
  entries land 0, -24, +24 or +48 clocks from line 200 (26, 24, 26 and 13
  of 89 frames). The harness moves each frame's line 200 to MAME's entry
  when one lies within two cycles. On the board, a VBL can land one
  instruction apart from MAME's: MS1-22's allowance.

## NS2-10 — The board's pictures, replayed from MAME's writes (closed for Assault, measured)

`sim/rtl/ns2_frames` with `PICS=` compares the board's pictures with
MAME's. MAME's picture F is captured at (F + 1) × 811,008 clocks, when the
board's frame F finishes. MAME draws its picture in bands, at the POSIRQ
line and at vblank, from the video state of those moments (NS2-2), so a
game that writes the video during the frame shows up differently from the
board's raster.

Assault, 700 frames from power-on, with MAME's fine quantum (NS2-8):
- **Against MAME's pictures:** 521 of 700 exact. The others are:
  - MAME's boot screen (1–21, a MAME artifact);
  - text written during frame 79 (the board shows it on the lines drawn
    after the writes; MAME's picture shows it partly);
  - the Start-press screens and the play frames from 326 on, whose writes
    fall during the frame.

**The C116 takes any byte of a word.** MAME maps it with
`umask16(0x00ff).cswidth(16)`: its 8-bit handler runs for an access to
either byte of the word, and takes the low lane. A 68000 byte write to the
even address (UDS alone) puts the byte on both lanes, so the C116 takes it.
- Finest Hour and Rolling Thunder 2 set their clip window's y registers
  that way, through the mirror at 0x44b000. The RTL required LDS and missed
  those writes; the replay ignored them too.
- Both now take them: the RTL on either strobe, the replay by taking the
  word's low byte.
- Dragon Saber, Cosmo Gang and Kyuukai Douchuuki also write the palette
  with such bytes (thousands a run). Their pictures matched before, so
  those writes repeat what the RAM already holds.

**The replay** (`tools/ns2_replay.py`). The capture logs every video write
with its clock (`writes.txt`). For each line of the board's frame F, the
replay takes MAME's state at the frame's start, plus:
- the writes made before the line's fetch (during the line before it), for
  its tiles, sprites, ROZ and registers;
- those made before its output, for its colours.

The model renders each distinct state once.
- **675 of 678 frames exact, line for line.** The other 3 frames have 4
  lines between them, each with a write inside that line's own fetch
  window, so the board may show either value. No line differs without one.

## NS2-11 — M3: the SDRAM front end and two refresh races (closed, measured)

`rtl/ns2_sdram.sv` runs `jtframe_sdram64` at 98.304 MHz, twice the core's
clock, from one PLL. Each bank takes requests through a four-entry FIFO
written at 49.152 MHz, and returns each 64-bit burst with a toggle. The
download writes through the controller's programming port.
`sim/rtl/ns2_sdram` downloads a pattern into all four banks under refresh,
then reads random bursts from every bank and checks every word.

**Found on the way:**
- **The model ignored the write burst mode.** jtframe sets the mode
  register's A9 (single-location writes); `sdram_model_burst.sv` wrote a
  whole burst of four, wrapping. It now honours A9.
- **Two refresh races in the programming path**, both local fixes in
  `jtframe_sdram64.v` (provenance):
  - the programming bank had `help` tied low, so an overdue refresh (which
    proceeds on `help`) could close its row between its ACTIVE and WRITE;
  - `noreq` is registered, so between two download words the controller
    could grant the refresh and the programmer in the same cycle, and the
    ACTIVE met the refresh's PRECHARGE ALL (tRAS). No bank is now granted in
    the cycle the refresh is.
- **Burst assembly.** A variable part-select inside a loop over banks
  assembled wrongly in the `-O2` build and correctly at `-O1`. The
  assembly is now one plain block per bank.

**Result:** 65,536 words downloaded under refresh, then 80,000 random bursts
(20,000 per bank, up to six in flight): 0 bad words, 0 timing violations.
Random rows cost about 30 fast clocks per burst per bank with all four
banks busy and a quarter of the time refreshing. The depth of the queue
does not change it (1: 30.9; 2-6: 29.7), so this is the controller's
random-row rate. M0's replayed streams, with their row locality, are the
bandwidth gate (NS2-3).

## NS2-12 — M3: the board from the SDRAM (open: the other sets, the NB boards)

`sim/rtl/ns2_hw` runs the whole board from the SDRAM (`ns2_board ROMS = 1`,
`ns2_mem`, `ns2_sdram`, the burst model), after the real download of the
set's image (`tools/ns2_image.py`).

- **The download** (`ns2_mem`) lays the image into the four banks:
  - it applies the board wiring MAME applies after loading: Metal Hawk's
    sprite reorder (one byte lands twice, one never) with its transposed
    copy, and Lucky & Wild's bit-reversed mask;
  - it writes the ROZ ROM twice;
  - it fills the tile class table.
  `DL_VERIFY` checks every region against the image: all exact.
- **The CPUs' ROMs** are behind caches (`ns2_rom_cache`: 16 bursts, the next
  one prefetched). On Assault's first 90 frames the misses cost 1,624
  clocks on the master, 64 on the slave, 6,702 on the audio CPU and 15,553
  on the MCU, of 73.8 M. That is 0.02% at most.
- **The C123 cannot run straight from the SDRAM.** A line asks for 444 tile
  rows and masks in bank 2, at about 15 clocks a burst for random rows:
  every other line overran (112 a frame) and text lost pixels.
  `ns2_tile_filter` (NS2-3's additions) answers most of them itself:
  - the class table: no mask for an opaque tile, nothing for a transparent
    one;
  - a 256-entry tile-row cache and a 256-tile mask cache;
  - each stream stays in request order, with several misses in flight.

  Only 0.5% of tile rows and almost no masks reach the SDRAM; the busiest
  line takes 2,818 of 3,072 clocks.
- **MAME wraps graphics codes** (`code % elements`). The image repeats a
  smaller graphics region through its slot (Golly Ghost's tiles are 384 KB),
  so the core's fetches wrap as MAME's do.

**Result, Assault's first 90 frames:** the pictures are M2's, frame for
frame: 67 exact, the same two tearing frames (24: 448 pixels; 79: 332),
and MAME's boot screen (1–21). There are no overruns and no SDRAM timing
violations, and every tile burst and mask byte equals the image.

## NS2-13 — M4: the standard bitstream's core fits, timing met (closed for the core, measured)

`sim/quartus/core_fit` compiles the standard bitstream's core with Quartus
17.0, without the MiSTer framework: `ns2_board` (ROMS = 1, no C45, C169 or
C355), `ns2_mem`, `ns2_tile_filter` and `ns2_sdram`. The ports other than
the clocks and the SDRAM are virtual pins.

**The first map** kept 116,347 registers and 7.9 Mbit of block RAM, more
than the device has. The causes, and the fixes:
- **RAMs duplicated.** A CPU port that read old data during its own write
  cannot be an M10K port, so Quartus built each RAM with two read ports
  twice: the tilemap, ROZ, sprite and palette RAMs, and the class table.
  Each CPU port is now Intel's true dual port template, where a write
  returns its own data. The CPU never takes data from a write cycle.
- **Arrays left as registers.**
  - The master's EEPROM (65,536 registers): its load port shares the CPU's.
  - The DPRAM's three write ports: port A is the 68000s'; port B alternates
    clocks between the 6809 and the MCU, each write waiting at most a clock
    for its turn.
  - The C139 RAM and the palette: their reads are registered as the
    template wants.
- **Blocks the bitstream leaves out** (`HAS_C45`, `HAS_C169`, `HAS_C355`):
  their RAMs, line buffers, requests and busy flags are gated, so Quartus
  removes them.
- **Small queues and jt51's shift registers** took a whole M10K each (21):
  they are now logic (`ramstyle "logic"`, `AUTO_SHIFT_REGISTER_RECOGNITION
  OFF`).

**Timing** (49.152 / 98.304 MHz) failed by 28.9 ns at first:
- **Sprite A's zoom step** was a divider. It is now a table of
  (32 << 16) / n.
- **The C140's mix** takes two clocks (the sample and volumes, then the
  products).
- **The bank arbiter's round robin** used `% N`. It is now a masked
  priority encoder.
- **The 6809, the HD63705 and the M37450** change registers only on their
  enables, at least 6 clocks apart. Their paths are 4-cycle multicycles
  (`core_top.sdc`).
  - Everything that takes their outputs does so on one of their enables,
    except the ROM caches.
  - The ROM caches latch the address 5 clocks after it changes
    (`ns2_rom_cache SAMPLED`).
  - This also removes the path from one MCU to the other through the
    shared cache.

**Result:**

| | |
|---|---|
| ALMs | 26,643 of 41,910 (64%) |
| registers | 38,304 |
| M10K | 433 of 553 (540 with the framework's 107, Appendix F) |
| setup slack, `clk` | +2.26 ns (slow 100C), +2.23 ns (slow -40C) |
| setup slack, `clk_sd` | +1.72 ns (slow 100C), +2.01 ns (slow -40C) |
| hold | met at every corner |

**The regressions after the changes:**
- M1: Assault, 201 of 201 exact.
- The C140 harness: 419,849 samples, all equal.
- The DPRAM writes against MAME: the C65 all 65,817, the 6809 all 2,325,
  the C68 all 14,846.
- M2 Burning Force: 678 of 700 pictures, all 699 replayed frames exact, as
  before.
- M3 Finest Hour: 287 of 300 pictures, as before. The audio cache waits
  96,798 clocks instead of 93,932.

## NS2-14 — M4: the NamcoS2 bitstream on the board (open: timing margin, the audio level against MAME)

`NamcoS2.sv` is the standard bitstream's top: the standard boards and Final
Lap / Four Trax (`HAS_C45`), the C65 or the C68. It follows GingaNin's
(OSD, keyboard, download and reset sequencing, video chain). What is new:

- **The PLL** (`rtl/pll_ns2.v`): 49.152 and 98.304 MHz from 50 MHz
  (fractional), and the SDRAM chip's clock at 98.304 MHz, 270 degrees
  (-2.54 ns), through an `altddio_out`.
  - `jtframe_sdram64` launches a command on an edge for the chip to take
    on the next, and takes read data on the edge after the chip drives it.
    With the pins' delays that leaves a window of about -4 to +2 ns.
  - A phase must be a multiple of an eighth of the VCO period. The VCO is
    491.6 MHz, so the step is 254.3 ps; `7628 ps` is 30 steps.
- **The set's configuration** (board code, MCU, wirings, the key custom's
  table) is a 32-byte block of the image at 0x00D6000
  (`ns2_romdata.config_block`), which the top latches from the download.
  The board stays in reset until it has arrived. `<switches>` carries only
  MAME's DSW port.
- **The .mra** (`tools/ns2_mra.py`) builds the image from MAME's
  `ROM_LOAD`s: parts, 16- and 32-bit interleaves, fills, and repeats for the
  graphics regions MAME wraps. `--check` assembles each `.mra` as MiSTer
  does and compares it with `ns2_romdata.build()`: all 49 of the bitstream's
  sets are equal.
  - An interleave cannot leave a lane empty. MAME loads one lane of the
    C140 voices (every set) and of the data ROM's second megabyte (rthun2,
    suzuka8h), and leaves the other at 0. The `.mra` repeats the loaded
    lane, and `ns2_mem` writes 0 there (`drom_empty`, config byte 3).
  - A set without a default NVRAM starts from all 1s, as MAME's
    `NVRAM(... DEFAULT_ALL_1)`. The image had zeros until this was found.
- **The NVRAM:** the master's EEPROM has a second port.
  - The image's default arrives with the ROM.
  - ioctl index 4 loads the `.nvm` over it.
  - An upload of index 4 saves it: Save NVRAM, or opening the OSD after the
    game has written the EEPROM.
- **The slow CPUs' caches follow the address.** `mc6809is` drives
  `ADDR = addr_nxt`, combinational from its data input, so its address can
  move after its enable. `ns2_rom_cache SAMPLED` takes the address on every
  clock from 5 after the enable to the cycle's end, and is ready only while
  what it took is the live address. The byte comes from the live address.

**On the board (192.168.1.138):**
- **Finest Hour.** It boots to "33 TIP / EXIT = 1P START", as MAME does at
  10 s and 45 s. After 1P Start comes the attract: the namco logo, the
  cockpit scene, the ROZ territory map. A coin gives "CREDIT 01" on the
  title screen, the same frame as MAME's.
- **Assault.** "35 WARNING 00180040" (its EEPROM starts all 1s), then after
  1P Start the attract demo with its ROZ terrain and sprites.
- **HDMI audio.** Assault's attract sound is there: RMS about 2,800, peak
  9,700 of 32,767. Left and right differ by an RMS of 7.5. Card 1 of the
  capture PC is the HDMI capture; card 2 is the analog input.
  - The first build peaked at 650. Its mix took `ym_left * 205` at 18 bits,
    which overflows; the products are now 25 bits.

**Fit** (Quartus 17.0, the framework included):

| | |
|---|---|
| ALMs | 36,817 of 41,910 (88%) |
| M10K | 532 of 553 |
| timing | met on the first build; the later ones miss by 0.38 and 0.03 ns |

The miss is on clk_sd, in `jtframe_sdram64`'s command mux into the SDRAM
address register that also drives DQM (the MiSTer wiring). It depends on
placement: a seed search is next.

**A write the download never meant.** `ns2_mem` takes a CLUT or NVRAM
word in two clocks, a byte each. In the second, its write branch also ran,
because the branch was a plain `else` (not taking a word), and issued an
SDRAM write with the last real write's address and the new word's data.
- That address was the MCU region's last word: the C68's reset vector.
- Once the image's NVRAM was all 1s, that vector became 0xFFFF. Super World
  Stadium '92's C68 then ran from 0000 and never wrote the DPRAM, and the
  game stopped at its "30 / 31 TIP" screen.
- `DL_VERIFY` found the one word (0xFFFF instead of 0x8100), and a write
  monitor in the SDRAM model showed its source. The branch now runs only
  while busy.
- On the board, Super World Stadium '92 now reaches its menus. Burning
  Force and Dragon Saber run their attracts.

**Timing.** Later builds missed by 0.38, 0.03 and 0.10 ns on clk_sd. The
lockstep build meets both core clocks (clk_sd +0.305, clk +1.696); the
framework's HDMI clock misses by 0.145 ns. Seeds 2
to 4 were worse (-1.0 to -1.3 ns), and three effort settings made no
difference.
- The miss was in `jtframe_sdram64`'s decode of the next command into A12/A11
  (MiSTer's DQM).
- The banks now drive A12/A11 only with ACTIVE, and the top ORs the write
  mask in. A write's cycle is never an ACTIVE: one command a clock, and the
  download's writes auto-precharge.
- The miss is now -0.09 ns, in the bank arbitration into the command
  register.

**Timing, the bank arbitration.** The last clk_sd misses were in
`jtframe_sdram64`'s randomised bank grant (`BAPRIO=0`, 64 cases on the
LFSR), into the command register. `BAPRIO=1` (bank 0 first, then 1, 2, 3)
is a priority encoder.
- In M3 it changes nothing measurable: Assault 277 of 300 pictures,
  busiest line 2,819 of 3,072 clocks (2,818 before), no overruns; Finest
  Hour 287 of 300, as before.
- Both core clocks now meet timing (clk_sd +0.119 ns, clk +1.829 ns). What
  is left is the framework's scaler (`ascal`, the HDMI clock, -0.18 ns): a
  matter of placement.

**Timing met on every clock.**
- A path from the download's index decode (`hps_io` `ioctl_index` into
  `jtframe_sdram64`'s `prog_en` mux, clk to clk_sd) now crosses through two
  flops in `ns2_sdram`. `prog_en` changes only as a download starts or
  ends, with no write in flight; `DL_VERIFY` stays exact.
- Of seeds 2, 3 and 5, seed 2 met every clock. It is pinned in
  `NamcoS2.qsf`.
- The build of the current RTL: clk_sd +0.163 ns, the HDMI clock +0.265,
  clk +1.419, hold met, no failing report lines.

**Final Lap 2 and 3's protection.** Both stopped at "RAM OK / ROM OK" (Final
Lap 3: "SYSTEM DOWN"). Their bus traces parted at 300000, where MAME's
`finallap_prot_r` answers. It returns fixed words at 0 and 1, and two tables
on a counter that reads of words 3 and 1ffff advance. `ns2_main` decoded
the window (`D_PROT`) but read 0 there; it now answers as MAME.

**Rolling Thunder 2: a write the ROM cache waited for.** After its boot the
game stayed black, in M3 and on the board, where MAME plays the story
intro. The cause:
- Its slave writes to 001000, inside its program ROM. MAME ignores the
  write.
- `ns2_cpu` held any access to the program ROM at its last DTACK count
  until the cache was ready. The cache is asked only on reads, so the slave
  waited forever.
- The master then waited for the slave to clear a flag in the tilemap RAM
  (409002), and never released the sound CPU.
- The hold is now for reads only. The intro plays in M3, and on the board.

The trail:
- `MDUMP` and `MDUMP_S` (M2 against M3) and `UDUMP` / `SDUMP` found that
  the 6809 was never released again.
- They then found the master's poll and the slave's stall.
- A probe of the lockstep's sources caught the slave held at a write
  (`s_rd` 0 at 001000).

**The CPUs' lockstep.** On the board no ROM makes a CPU wait. Here a cache
miss stops one CPU, which moves the races between the CPUs (the
master / slave and DPRAM handshakes).
- Every CPU now stops on any CPU's miss:
  - `ns2_main`: the 68000s' phases, `en_phi*` gated;
  - `ns2_c65` / `ns2_c68`: `div`;
  - `ns2_sound`: `ph`, with `fallE` and `fallQ` gated.
- Their timing against each other is then M2's. Against the video it moves
  by the misses, about 0.01% of the time.
- M2 with injected master stalls (`STALL=`, `dbg_stall`) still plays
  Rolling Thunder 2's intro, with small sprite differences from frame 350.
- **Final Lap** stopped at "RAM OK / ROM OK", in M2 too (the FL boards'
  first whole-board capture, `finallap_board`). Against MAME's bus trace
  two reads differed:
  - C116 registers 6 and 7 read 0xff in MAME (`namcos2_base_state::c116_r`,
    "fix for finallap boot");
  - the C139's registers at 4a0000: `status_r` reads 4 and the others 0 (the
    core had nothing there; the game then said "SCI ERROR").
  With both, M2 runs Final Lap's attract like MAME's. Ranking row 6's
  colour cycles at another phase: 39 of 700 pictures are exact.
  The top also now starts the analog channels and dials at MAME's power-on
  values (`tools/ns2_ports.py`, config bytes 21-32): the wheel centred, the
  pedals up.

The harnesses gained, for this:
- `MDUMP` (the master's accesses), `UDUMP` and `SDUMP` (the MCU's and the
  6809's DPRAM writes), in both;
- `UTRACE` (the MCU's first cycles) and the boot script's Start press, in M3.

**Open:**
- the timing margin on that path;
- the audio level against MAME's (`-wavwrite` from the oracle build wrote
  silence; to be measured another way);
- then the other sets, the inputs of the sets with analog controls, and
  M5.
