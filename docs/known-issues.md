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

## NS2-8 — M2: the whole board against MAME's bus traces (closed: the C140 in NS2-26, the C68 in NS2-13)

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

## NS2-14 — M4: the NamcoS2 bitstream on the board (open: timing margin; the audio against MAME: NS2-26)

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

## NS2-15 — M4: every set on the board: the standard, Metal Hawk, Steel Gunner, Suzuka and Lucky & Wild bitstreams

**The standard bitstream's 49 sets on the board.** Each was loaded with 1P
Start at 45 s and captured at +15 s and +30 s: 22 parents and 27 clones.
- **Before the fixes:** all ran but Final Lap 2 and 3 (NS2-14's
  protection).
- **Final Lap 2 and 3** now run: their title, then the GP rankings.
- **The Bubble Trouble sets** are `ROT180` in MAME: the board's picture is
  upside down. Config byte 3 bit 6 marks a ROT180 set. The top turns such
  a set 180 degrees through `screen_rotate`'s flip (its framebuffer), with
  the scandoubler off, as when rotating. The new OSD "Flip screen" inverts
  the turn. On the board, Bubble Trouble is upright (a stale `.mra` there
  had shown it inverted).

**NamcoS2_MH, Metal Hawk's bitstream** (`NamcoS2_MH.qsf`, the `NS2_MH`
macro in `NamcoS2.sv`):
- It has the C169, and neither the standard ROZ nor the C45 road.
  `HAS_ROZ` in `ns2_video` removes `ns2_roz`, and with `HAS_C45` 0 the
  128 KB ROZ / road RAM too.
- **Its first fit:** 477 of 553 M10K, 87% of the ALMs. Seed 5 meets every
  clock (clk_sd +0.541 ns).
- **Its first build showed line noise on the board.** M3 reproduced it:
  the C169 overran every other line (busiest line 3,070 of 3,072 clocks).
  - The C169 asked for a burst and a mask byte for every pixel of both
    layers.
  - A pixel in the same tile row half as the last request now takes that
    request's burst and byte. At a zoom near 1, one burst serves 8 pixels.
  - Each waiting pixel keeps its request's number. At most 14 wait, so a
    burst's slot lasts until its last pixel is drawn.
- **Results:**
  - M1 exact for both C169 boards: Metal Hawk and Lucky & Wild, 101 of 101
    each.
  - M3 Metal Hawk: 375 of 400 pictures, no overruns, busiest line 1,974.
  - M2 Metal Hawk (`metlhawk_board`): 669 of 700 pictures, the replay 696
    of 699.
- `tools/ns2_mra.py` writes Metal Hawk's two `.mra`s for `NamcoS2_MH`.
  `build.sh` builds a bitstream by `PROJ=` (`output_files_MH`).
- The rebuilt bitstream (seed 5, every clock met) runs Metal Hawk on the
  board.

**NamcoS2_SG, Steel Gunner's bitstream** (`NamcoS2_SG.qsf`, `NS2_SG`):
- Only the C355 sprites: no sprites A (`HAS_SPRA` 0 removes `ns2_sprite_a`
  and its 16 KB RAM), no ROZ, road or C169. 482 of 553 M10K, 89% of the
  ALMs.
- **The C355 missed clk_sys by 45 ns.** Five groups of paths, all
  rewritten without changing a picture:
  - The walker's row: two `zt` divisions, a `zstep` division and a multiply
    in one clock. A size needs only whether zt(l, k) = 4096k / l reaches
    2048, exactly when 2k >= l: no divider. `zstep` is a 1024-entry ROM,
    read for the covering row (a new state, `L_SROW`, takes its product)
    and for each column's job.
  - The pass: the format offset's fractions by a 17-step division
    (`P_ZT`), the offset registered before it is added.
  - The columns: their sizes as the rows'.
  - The drawer: two stages, positions and the window test, then the pens.
    The line waits for the second stage before it ends.
  - M2 on the new RTL: sgunner and sgunner2 give the same 700 pictures as
    the old, byte for byte.
- Seed 4 meets every clock (clk_sys +1.187 ns, clk_sd +0.459, HDMI
  +0.213).
- **On the board:** Steel Gunner's attract and Steel Gunner 2's (C68) title
  and play screens. (A first try drew a blank screen: the board had no
  `sgunner*.zip`, so the ROMs and the default EEPROM loaded as zeros.)
- M2 against MAME: 145 and 304 of 700 pictures exact. The replay finds no
  line that differs: the rest are MAME's sprite RAM writes landing inside
  the frame (NS2-11).
- `sim/rtl/ns2_hw`: `make VARIANT=SG|MH|SZ|LW` builds a bitstream's blocks
  (`obj_<variant>`); `SDRAM_FILL=seed` starts the SDRAM with random words,
  as the board keeps the last core's.

**NamcoS2_SZ (Suzuka 8 Hours 1 and 2) and NamcoS2_LW (Lucky & Wild).**
- The whole NB set (C355, C45 road, C169) needed 702 of 553 M10K. The
  largest: the ROZ / road RAM 128, the two 68000 work RAMs 64 each, the
  C355 RAM 82, the C169 RAM 64, the tilemap RAM 64, MiSTer's `crt_vsize`
  26.
- **`WRAM_SD`: the RAMs into the SDRAM (Appendix F).** Each 68000's 64 KB
  work RAM, and the C139's 16 KB, sit in bank 1 (300000, 308000, 310000)
  behind `ns2_wram_cache`:
  - A direct-mapped cache of 256 lines of four words (the C139's: 32) in
    block RAM, written through, three blocks a CPU.
  - Its tag and word are read every clock, so a hit answers as the RAM
    did. A miss holds the CPUs (the lockstep) while one burst fills the
    line.
  - A write updates its line and goes out through a four-entry FIFO; a
    full FIFO holds the next write cycle. A fill waits for the FIFO: the
    bank takes a client's requests in order.
  - The C139's RAM is on the shared bus: its read waits at the capture
    step, as the data ROM's does, and its write goes out there.
  - The SDRAM path takes writes: `ns2_sdram`'s bank FIFOs carry a write's
    word and mask (`WEN`, jtframe's `BA1_WEN`), and `ns2_bank_arb` queues
    no tag for one.
  - The download first clears the three regions: MAME's RAM starts at 0,
    and the board's SDRAM keeps the last core's data.
- Suzuka has no C169: its own bitstream, 481 of 553 M10K. Lucky & Wild
  also narrows the CRT V-Size to one step each way (`crt_vsize`'s ring):
  540 of 553. Seed 4 meets every clock on both.
- **Results:**
  - M2 (a model of the SDRAM clients, eight clocks a burst): Suzuka 662 of
    700 pictures, Lucky & Wild 289, as with the RAMs in block RAM (661,
    289).
  - M3 through the SDRAM, which starts random (`SDRAM_FILL`): Suzuka 163
    of 200, Lucky & Wild 115 of 200 (block RAM: 116), no violations.
  - On the board: Suzuka 8 Hours 1 and 2's attract (the road), Lucky &
    Wild's (the C169, the road, the C355).
- The shared RTL changed every bitstream. MH (seed 5) and SG (seed 4)
  still meet every clock; the standard one missed clk_sd by 0.195 ns on
  seed 2 and meets every clock on seed 3 (clk_sd +0.139 ns). M2's default
  build gives Suzuka's and Lucky & Wild's 1,400 pictures unchanged, byte
  for byte; Metal Hawk and Steel Gunner 2 run on the board with the
  rebuilt bitstreams.
- **The standard sets loaded the Suzuka bitstream.** MiSTer finds an
  `.mra`'s `<rbf>` by prefix, and `NamcoS2` is a prefix of every other
  bitstream's name: with `NamcoS2_SZ_*.rbf` in the cores folder, Assault
  loaded it (its OSD name in `/tmp/RBFNAME`). The standard `.mra`s now name
  `NamcoS2_STD`, a prefix of no other; the bitstream's own name stays
  `NamcoS2`. Assault, Final Lap 2, Rolling Thunder 2 and Dragon Saber then
  load it, and Suzuka its own.
- `releases/` holds the five bitstreams, `Arcade-NamcoS2_<STD|MH|SG|SZ|LW>_<date>.rbf`.

## NS2-16 — Lines of garbage in play: the SDRAM's bank priority starved the tile fetch (closed, measured)

**On the board:** in Phelios's play, now and then one line (a vertical line
on the rotated screen) shows a flat green and white stripe, black to x 262,
over the playfield; sprites draw over it. 3 of 40 captured frames of play.

**The cause, measured in M3** (`sim/rtl/ns2_hw`'s `PLAY=F`, the play
script's coin, Start and inputs, as MAME's capture need not reach play):
- From frame 803 the C123 overruns (`busy 01`): 61 frames of 1,150. A line
  it has not finished is never started (the C123 takes a `start` only
  idle), and the line buffer shows stale data: the stripe.
- `C123_LOG=F` prints each line's C123 clocks. In the heavy frames every
  line runs 3,041-3,066 of its 3,072: 1,728 drawing six planes, and about
  1,500 of the fetch waiting for the tile filter's acknowledgements. A
  light line with the same six planes takes 1,974.
- The SDRAM was not busy: 25% of the data bus's cycles. The filter misses
  21-35 of a line's 220 tiles, but each miss took 180-290 clocks to
  return, so the in-order queue (16) filled behind it for about 1,000
  clocks a line.
- The misses waited for bank grants: jtframe's fixed priority serves bank
  0 first, then 1, 2, 3. Banks 0 and 1 (the CPUs' caches, the ROZ's
  stream, the C140's voices) always had a request queued; bank 2's tiles
  waited about 750 clk_sd a line.

**The fix** (`jtframe_sdram64.v`, a local change): the fixed order is 2, 3,
0, 1. The tiles and the sprites are the streams a line must wait for; the
CPUs' caches only hold the CPUs, and the ROZ and the C140 run deep queues.
The same priority encoder, so the same timing (clk_sd +0.694 ns on the
standard bitstream's seed 3).
- Phelios, frame 802's lines: 1,974-1,984 clocks; a miss returns in 10-14
  clocks; the queue is never full. 0 overruns in 1,150 frames (busiest line
  2,812). The master's cache waits 0.39% of its clocks (0.37% before).
- M3 on every board, no overruns: Assault 297 of 400 pictures (the C123 had
  overrun there too; busiest line 2,732), Finest Hour 287 of 300, Metal
  Hawk 113 of 120 (its C169 had overrun; now 1,974), Steel Gunner 2 166 of
  200, Suzuka 163 of 200, Lucky & Wild 115 of 200, as before.
- On the board: no stripe in 187 captured frames of Phelios's play.

**What did not help** (reverted): holding back banks 0 and 1 on alternate
clocks, or alternating two priority orders (the grant's extra input cost
clk_sd -0.6 ns, and the overruns stayed); the tiles over two banks (bank 3
was the last in the order: worse).


## NS2-17 — No sprites in play on the C355 boards: the sprite RAM's page-0 mirror (closed, measured)

**On the board:** Steel Gunner 1 and 2 and Suzuka 8 Hours drew no sprites
in play: no enemies, no sight, no bike, only the tile and ROZ layers. The
player could not see what shot them. The release before NS2-16 (d10672c5)
did the same, so NS2-16 did not cause it.

**Why M1 passed:** the video harness (`sim/rtl/video_state`) loads MAME's
captured C355 RAM straight into the RAM, and renders Steel Gunner's play
exactly (5 of 5). What MAME does on the CPU's write never reaches it.

**The cause, measured in M3** (`sim/rtl/ns2_hw`, `VDUMP=F` writes the C355
RAM at frame F's end): Steel Gunner's attract loses its sprites from frame
153, the zoomed logo. At frame 170 the RTL's 0xa100 words match MAME's
except the list at 0x1000-0x10ff (MAME: 0x100, 1, 2, 3 ...; the RTL: 0)
and the first table entry at 0x0000. MAME's
`namco_c355spr_device::spriteram_w` writes words 0x8000-0x8fff (the CPU's
810000, the table) and 0xa000-0xa1ff (814000, the list) into page 0 as
well (0x0000, 0x1000), where the sprites are drawn from. The game writes
its lists there, so page 0's list stayed empty.

**The fix** (`ns2_video.sv`): the CPU port writes the page-0 copy on the
clock after the write. The select is a one-clock pulse, and the address
and data are held through the access's capture step, so the port is free.
There is one address mux on the port, and it still infers as a true
dual-port RAM.
- M3, Steel Gunner: frames 114-199 exact, the sprite frames included; 183
  of 200 (the rest are the boot's RAM test, as before). Suzuka 163 of 200
  and Lucky & Wild 115 of 200, unchanged (their first 200 frames write
  page 0 directly). M1 unchanged (exact).
- On the board: Suzuka's bike, rider, pit crew, signs and dust draw in
  play.

## NS2-18 — M5: the analog controls (closed for the wheel, pedals, guns and Metal Hawk's stick, measured)

The driving games' wheel and pedals, the light guns and Metal Hawk's stick
reach the MCU's analog channels (`rtl/ns2_controls.sv`), as MAME's ports
and ranges (namcos2.cpp). Each set's mode is config byte 33, with MCUB's
and MCUH's idle values in bytes 34-35 (`tools/ns2_romdata.py` CONTROLS).
- **The ports as MAME reads them.** The joystick sets keep MAME's default
  ports. Every other mode sets only its own inputs' bits and holds the rest
  at MAME's idle values. MAME reads a bit no field defines as 0 (Dirt Fox
  MCUB 0xa0, Suzuka 0xc0, Metal Hawk MCUB 0xc0 and MCUH 0xa0, as MAME's
  captures read them). Final Lap's MCUB and MCUH are DIPs (car type,
  automatic car select, on-screen diagnostics) except the gear: the
  default map's d-pad would have set them.
- **Wheel and pedals:** the left stick, or the d-pad stepping 8 a frame
  and returning to centre, gives the wheel (AN5, 0x01-0xff). Button 1 or
  the right stick up gives the accelerator (AN7, 0-0x80); Button 2 or the
  right stick down gives the brake (AN6, 0-0x40), ramping 16 and 8 a frame
  as MAME's key delta. Button 3 toggles the gear (MCUH 5) in Final Lap and
  Four Trax. Dirt Fox's gears are MCUB 5 and 7 (the d-pad's up and down).
  Final Lap and Dirt Fox have no Start: a credit starts them.
- **Guns:** the position on the displayed picture, 0-255, as MAME's
  crosshair maps it, turned 180 degrees for the ROT180 sets. Bubble
  Trouble's values are reversed (its crosshair's scale is -1). A MiSTer
  gun or the left stick aims; the mouse aims for player 1 (left button
  trigger, right button missile), whichever moved last. The OSD crosshair
  is the core's (white player 1, yellow player 2 once player 2 aims).
- **Metal Hawk:** the left stick flies (AN6 X, AN5 Y, 0x20-0xe0); the
  right stick's Y or Buttons 4 and 5 move the lever (AN7).
- The outputs are registered: the combinational ports put the MCU and
  video paths at clk_sys -0.35 ns. A clock of latency on an input changes
  nothing a game can see.

**Measured:** `sim/rtl/ns2_controls` checks every mode against MAME's
ports (73 checks). On the board:
- Final Lap and Four Trax started and reached speed; Final Lap steered.
  Suzuka: 140 km/h, leaning into a corner. Dirt Fox: 82 km/h, and the
  d-pad's down shifted LOW to MID.
- Golly! Ghost! and Bubble Trouble: the core's crosshair sits at the centre
  of the game's own sight, at the centre and part-way across (the games
  clamp their sight inside the screen at the edges).
- Steel Gunner's results screen counted player 1's shots (MISS SHOT 2);
  Steel Gunner 2's missile count fell with Button 2.
- Metal Hawk flew left and right, the lever moved the altitude, and Button
  1 scored.

- Lucky & Wild: the accelerator took the car from 60 to 138 km/h, the brake
  from 78 to 0, and the core's crosshair sits in the game's sight.

**Open:** Assault's twin sticks (closed by NS2-23). Metal Hawk's ROZ layer shows dark and torn lines
at some zooms on the board. The release before this change shows them too,
so this change did not cause them.

## NS2-19 — Black screens and crashes on other boards: no refresh in the download, and the SDRAM clock's phase (closed: confirmed with NS2-27's follow-up)

**Reported:** on other users' boards some games boot to a black screen, or
crash after a couple of minutes. The test board shows neither.

**Compared with the other kuzecores** (SandScrp, GingaNin, NMK16, NMKBP964,
MS1BCD, MS1Z; no reports from their users), which all share one `sdram.sv`:

| | the other kuzecores | NamcoS2 (before) |
|---|---|---|
| controller | `sdram.sv`, 96 MHz, CL3 | `jtframe_sdram64`, 98.304 MHz, CL2 |
| chip clock | the controller's, inverted (180 degrees) through an `altddio_out` | a PLL output at 270 degrees through an `altddio_out` |
| refresh | a free-running timer in the SDRAM's clock (740 clocks, 7.7 us), from the PLL's lock on | `rfsh` from the board's raster (`hcnt >= 300`), 9 a line |
| SDRAM I/O constraints | none | none |

**1. No refresh while the board is in reset.** The raster stops in reset
(`ns2_video`: `hcnt <= 0`), so `rfsh` never rises. The reset lasts through
the ROM download, its settling, the DIP wait and any OSD reset. The first
rows written by the download (the CPUs' programs, at the image's start)
wait unrefreshed until the game starts. The ARM's download of the 18 MB
image takes seconds, and a chip keeps its bits only 64 ms by the spec
(more by luck, less when warm). A decayed program word is a black screen,
or a crash when the code first runs. The SDRAM model in the sims keeps its
contents forever, so no sim showed it. It now counts REF commands
(`sdram_model_burst.sv`, `ref_n`, `ref_gap_max`). M3, Phelios:
- before (`RFSH_OLD=1`): 0 REFs in the 1.59 s download; the longest gap is
  the whole download.
- after: 9,219 REFs per 64 ms in the download (longest gap 62 us), and
  10,240 in play as before. The download takes 0.9% longer; the pictures
  are as before.

The fix (`NamcoS2.sv`): while `reset` holds the board, a free-running
count of the line period (3072 clocks) drives `rfsh`; otherwise the
horizontal blank does, as before, where refresh takes nothing from a
line's fetches.

**2. The chip clock's phase.** The pins had no constraints, so nothing
checked the phase. The design assumed the 270-degree clock was 2.54 ns
early. TimeQuest shows the forwarded clock reaches SDRAM_CLK about 5.4 ns
after clk_sd reaches the I/O registers (the global network, 3 ns to the
DDIO cell, its 1.7 ns, the output buffer's 2.5 ns). The chip's clock was
therefore about 2.9 ns late, not early.

`NamcoS2.sdc` now constrains the interface: CL2 at the MiSTer boards'
slowest chips (tAC 6.0, tOH 2.5, tIS 1.5, tIH 0.8 ns), traces 0.3-1.0 ns,
and the read taken two clk_sd edges after the chip's edge
(`jtframe_sdram64`, SHIFTED=0). The standard bitstream's seed-3 netlist,
worst of the four corners, with the chip clock moved from 270 degrees:

| chip clock | read setup | command setup | command hold |
|---|---|---|---|
| 270 degrees (before) | -2.27 | 3.44 | -0.68 |
| 217 degrees (-1.5 ns) | -0.77 | 1.94 | 0.82 |
| 180 degrees (the other kuzecores') | 0.28 | 0.90 | 1.86 |
| 164 degrees (-3.0 ns) | 0.73 | 0.44 | 2.32 |
| 146 degrees (-3.5 ns) | 1.23 | -0.06 | 2.82 |

The read's setup fails by 2.3 ns at the slow corner. It passes on a
board with a fast chip, short traces and a cool FPGA, as the test board's.
A slower module, or the board warming over the first minutes, closes the
window: a garbled fetch is a crash, or a black screen at boot. The window
where all three pass is about 150-190 degrees. The chip clock is now 171
degrees (`rtl/pll_ns2.v` `4832 ps`, 19 of the VCO's 254.3 ps steps), its
centre. The constraints make every build check it.

## NS2-20 — Hold on the SDRAM's clock crossings: the request FIFOs and the bursts back (closed, measured)

**Seen:** after NS2-19's rebuild, Suzuka failed on eight seeds, and half of
them on hold at clk_sd (-0.46 to -0.81 ns). The paths are `ns2_sdram`'s
request FIFO entries (clk) into jtframe's latch (`ba*_addr_l`, clk_sd):
one flop, one LUT, one flop in the same LAB. clk_sd's network reaches its
registers about 1 ns after clk's (skew +0.99 ns), and the fitter, with
hold optimisation on all paths, had no route to pad inside the LAB. Lucky &
Wild then showed the same on the bursts back (`data0` into `ns2_bank_arb`,
clk_sys, -0.30 ns).

**A real hazard, not only a report:**
- Out: a push into an empty FIFO changes the entry and the write pointer
  (hence `pend`) on one clk edge. On the shared clk_sd edge the latch could
  take `pend` early and only some bits of the new address: a read of the
  wrong address.
- Back: `ns2_sdram` changes a bank's data and toggles `valid_t` on one
  clk_sd edge, and `bank_arb` took the data on the clk edge it saw the
  toggle. On a shared edge that is an early toggle with part of the burst.

**The fix:**
- Out (`ns2_sdram.sv`): the write pointer crosses in Gray code through a
  clk_sd register, and `pend` comes from that. The controller sees a request
  at least one clk_sd edge after its entry is written, never on that edge.
  The read pointer goes back to clk the same way, so the FIFO is seen full
  late, never too full.
- Back (`ns2_bank_arb.sv`): the toggle goes through a clk register, and the
  burst is taken a clk edge after that, never on the edge it changes. It
  has held for more than 10 ns by then, and `ns2_sdram` holds it for two
  core clocks.
- `NamcoS2.sdc`: the hold check of exactly those paths (the FIFO entries,
  the Gray pointers, the bursts and the toggle) moves to the edge before.
  Setup is checked as before.
- The cost is a clk_sd cycle for a request into an empty FIFO, and a clk
  cycle for a burst back.

**Measured:**
- M3: Phelios 39 of 40 pictures and Lucky & Wild 53 of 60 (the same 7
  frames) as before. The data cache waits 0.12% of its clocks (0.11%
  before).
- Phelios's play (`PLAY=500`, NS2-16's scene): 0 overruns, busiest line
  2,820 of 3,072 (2,812 before). Frame 802's lines take about 1,980 clocks;
  a tile miss returns in 14.8 on average; the queue is never full.
- Quartus: every build passes hold on clk and clk_sd (+0.22 ns or better),
  and the SDRAM pins pass (+0.62 ns or better). Passing seeds: STD 3, MH 5,
  SG 12 (and 13), SZ 5 (and 14), LW 22.
- On the board: Phelios, Metal Hawk, Steel Gunner 2, Suzuka and Lucky & Wild
  boot and play on the five rebuilt bitstreams.

## NS2-21 — Metal Hawk's striped ROZ: the C169's mask fetches, a tile cache (closed, measured)

**On the board:** zoomed out (a game starts at altitude 400, and in play),
every other line of Metal Hawk's ROZ is black and the rest look stretched
and torn. Low in the attract demo the picture is clean. The release before
NS2-17 shows the same.

**Measured in M3** (`PLAY=900` against `metlhawk_play`, MAME's capture with
the same script): from frame 1021 the C169 overruns 112 lines a frame (every
other line), busiest line 3,070 of 3,072. The control words match MAME's
(frames 1100, 1200), and M1 renders the same states exactly (240 of 240,
busiest line 2,351, even with 40 clocks of random stall). So it is the
real SDRAM path, not the state or the renderer:
- In play the layers are zoomed out 2-6x at an angle, and Metal Hawk's are
  turned 90 degrees. Each pixel of a line is in a burst of its own, so NS2-15's
  "a burst serves 8 pixels" never happens: 576 bursts and 576 mask bytes a
  line.
- `C123_LOG` (frame 1100): a rendered line takes bank 0 243 bursts, bank 1
  238, and bank 2 488 (the mask, and the tiles). A random burst costs 10-11
  clk_sd, so the mask alone is more than a line (6,144 clk_sd) on bank 2,
  twice banks 0 and 1's load. The C169 misses the next line's start; every
  other line is lost.
- The mask cannot come from the pixels (the masked-off pixels are ordinary
  colours), nor be baked into the tiles: the two codes of a tile have
  different masks in 8,188 of 8,192 cases.

**The fix** (`ns2_c169.sv`, `MCACHE`, Metal Hawk's bitstream only): a cache
of 512 tiles' masks (32 bytes each, 16 KB of M10K) by the code's low 9 bits.
- The prefetch asks for a tile as the pixel's map word arrives, up to 14
  pixels before the pixel needs it. A fill is four bursts in one row.
- A pixel leaves FIFO A only when its tile is in, and takes its mask bit
  with it, so a later fill of the same entry cannot change it (an evicted
  tile is fetched again).
- A fill's first burst marks the entry pending, and its last marks it
  filled. The fills run on through a reset (the memory system does not
  reset with the video), and reset clears the tags.
- The mask port now returns the burst (`ns2_mem` no longer picks the byte).
  Lucky & Wild (no M10K to spare, and no overruns) keeps a mask byte a
  pixel, its byte picked in `ns2_c169`.
- Found on the way, in M1: a tile went into the in-flight ring at its
  fourth burst's acknowledgement, but its bursts can come back before that,
  and were credited to a stale entry (a pending tag with no fill behind it:
  the C169 waited forever). It goes in as its first burst is asked for.

**Measured:**
- M1: Metal Hawk's play 240 of 240 exact, no overruns, busiest line 2,364
  (2,334 with random stalls); its attract 51 of 51; Lucky & Wild 51 of 51.
- M3, the same game start: 0 overruns (112 lines a frame before), busiest
  line 2,535. At frame 1100 a line takes bank 0 288 bursts, bank 1 288 and
  bank 2 1: the masks come from the cache. The ROZ matches MAME's; what
  differs is a band of the top lines from frame 1000 and a sprite's position
  (as before the cache: the timing of the play script against MAME's).

**The builds:** with the cache, Metal Hawk and Lucky & Wild missed clk_sd on
eight seeds (-0.06 to -0.64 ns). 48 of the worst 49 paths end at
`jtframe_sdram64`'s command register, through the grant's priority mux: the
cache only moved the placement. A local change there (`jtframe_sdram64.v`):
a bank's command is NOP unless it holds the grant, and one bank at most
does, so the banks' commands merge by AND. The rest selects on registers
(init, refresh, the programmer). In simulation the merge is compared with
the mux on every clock: 0 differences through the download, the refresh and
play (Phelios, Lucky & Wild, Metal Hawk), the pictures as before, 0 SDRAM
violations. Metal Hawk's seed 6 meets every clock (clk_sd +0.144 ns), and
Lucky & Wild's seed 27 (worst setup +0.183 ns); the cache takes 17 M10K
(492 of 553).

**On the board:** Metal Hawk's game start at altitude 400, and its play, draw
the ROZ whole: no black lines, nothing torn. Lucky & Wild (seed 27; no
cache, its C169 keeps the per-pixel fetch) boots and runs its attract as
before.

The command merge is in the SDRAM controller every bitstream shares, so the
release of 2026-09-28 rebuilds all five (STD 5, MH 6, SG 12, SZ 5, LW 27),
each tested on the board.

## NS2-22 — Flip: the test mode's FLIP was lost to a DIP reset, and the OSD's Flip screen reached only HDMI

**Reported:** changing a game's flip does not save, and the OSD's Flip
screen does nothing.

**The games' flip is a test-mode setting in the EEPROM, not a DIP.** Phelios's
GAME OPTIONS has FLIP; set ON, the C123 turns the tilemaps at once (on the
board too). MAME shows when the game keeps it: with the Service Mode DIP on,
FLIP set ON, then the DIP off, the EEPROM's two option bytes change on the
frame after the switch goes off (a per-frame poll of 0x180081 / 0x180091),
and the game restarts turned. On the core, MiSTer sends every DIP change as
an ioctl session (index 254), and the core held the board in reset for any
session: the switch went off inside a reset, the game never wrote, and the
`.nvm` (saved by hand after) was unchanged byte for byte.

**Fix:** after the first `<switches>` of a load, a DIP session no longer
resets (`dl_hold` in `NamcoS2.sv`; the ROM and NVRAM loads still do, and
"Reset to apply" still resets). The EEPROM's dirty flag is cleared only by
the NVRAM's own load and save, not by a DIP session, so opening the OSD
after leaving test mode saves the `.nvm`.

**The OSD's Flip screen** turned the picture through screen_rotate's
framebuffer, which only the HDMI scaler reads, and was off under direct
video: on the analog board and direct video it did nothing. The other cores
mirror their readback in the core, but here the board draws each line during
the one before, and the games change registers and video RAM mid-frame
(NS2-5's bands), so the picture cannot be drawn bottom-up.

`rtl/ns2_flipbuf.sv` turns it after video_retime, in CLK_VIDEO:
- Each frame is written to DDR as it is shown (two frames, 144 words a line
  of two pixels each, at 0x30000000; screen_rotate's buffers are at
  0x24000000). The next frame's time shows it turned: line y is the stored
  line 223 - y, fetched during line y - 1 into the half of a two-line buffer
  not being shown, and read backwards. One frame late while on; off, the
  stream passes unchanged.
- The writes go through a 64-pair FIFO; a line's read is 9 bursts of 16,
  with the controller back in IDLE between them, where a FIFO a quarter full
  writes first. The first line of a frame is read once the last one written
  has left the FIFO.
- The DDR port is screen_rotate's unless the flip buffer has a frame or a
  transfer in hand. With Orientation's quarter turns (HDMI only)
  screen_rotate still does the turn. The scandoubler and CRT Adjust now work
  with Flip screen on.
- Cost: 3 M10K, a 64 x 50 MLAB FIFO.

**Measured (Verilator, `sim/rtl/ns2_flipbuf`: the module alone with a DDR model):** a 384 x 264
stream, every pixel of frames 2-5 the previous frame turned (258,048
pixels): with random wait states (1 in 4) and 5-25 clocks of read latency,
and with 1 in 2 and 50-350 clocks (the FIFO's peak 27 of 64; before the
interleave it overflowed at 89). Switching on and off over 12 frames (`SLOW=1` too): each frame turned or
straight as expected (774,144 pixels), and the port free through the
picture of a frame with the flip off.

**On the board:**
- Flip screen (Steel Gunner, HDMI): the picture turned whole, no seam or
  swapped half, and back when off.
- Phelios (the standard bitstream): Service Mode on from the OSD entered
  the test mode without a reset; FLIP set ON turned the picture; Service
  Mode off restarted the game turned, and opening the OSD saved the `.nvm`
  at once (the option bytes changed; the rest of the options as before).
  Loaded again, the game starts turned.
- Steel Gunner: the same save works (MAME's test mode reads FLIP ON from
  the saved `.nvm`). Its attract ignores FLIP, in MAME too.
- The capture sees HDMI only; the analog output is not measured.

**The builds:** the flip buffer moves the placement, and the SDRAM
controller's grant paths (`cmd`, `sdram_a`, `dq_pad`, clk_sd) missed by 0.05
to 0.3 ns on some seeds. One standard-bitstream build missed hold on
hps_io's `video_calc` (the video's measurements, CLK_VIDEO, into the HPS's
register, clk_sys): a false path now, as the HPS polls values that hold for
frames. The DIP bank's false path is gone, as it now changes while the game
runs.
Seeds: STD 5, MH 9, SG 13, SZ 6, LW 33, every clock met, setup and hold (the
flip buffer adds 3 M10K: LW 544 of 553). On the board with these: Phelios
as above; Suzuka 8 Hours with Flip screen (the road whole, turned); Metal
Hawk's demo (the ROZ clean); Lucky & Wild with Flip screen; Steel Gunner's
attract.

## NS2-23 — Assault's twin sticks (closed, measured)

MAME's `assault` ports (Assault, Assault (Japan), Assault Plus) give each
player two 4-way sticks, a tank's two tracks: the left stick on MCUB (up 5 /
4, down 3 / 2, left 1 / 0, P1 / P2) and MCUH (right 7 / 6), the right stick
on MCUH (up 3 / 2, down 1 / 0) and the dial port MCUDI0 at the MCU's $3000
(right 1 / 0, left 3 / 2); fire MCUH 5 / 4. Mode 0 (MAME's default ports)
had put Button 2 and Button 3 on the right stick's up and down by the same
bits, and nothing on its left and right.

Control mode 0x04 (`tools/ns2_romdata.py` CONTROLS, `rtl/ns2_controls.sv`):
- The left and right analog sticks are the two sticks (4-way: the larger
  axis past 12). The d-pad drives both alike: forward, back, sideways, but
  only while neither analog stick is pushed. (At first a stick not pushed
  followed the d-pad, and MiSTer presses the d-pad from the left analog
  stick: the left stick alone drove both tracks, the tank forward instead of
  turning. A virtual two-stick pad on the board (uinput, the firmware's own
  mapping) showed it, and shows the fix: the left stick alone turns the
  tank.)
- Turn Left (B3) pushes the left stick down and the right up; Turn Right
  (B4) the reverse; Sticks Apart (B2) and Sticks Together (B5) push them
  out and in. The buttons win over the sticks.
- The controls now drive the dial port (MCUDI0-3), MAME's power-on values
  (config bytes 29-32) except Assault's bits. Player 2's right stick is
  wired (hps_io `joystick_r_analog_1`).

**Measured:**
- `sim/rtl/ns2_controls`: each stick direction, the d-pad, the four
  buttons and fire, both players, on the bits above (73 checks, all pass).
- MAME, Assault in play: both sticks up drive the tank forward; the left
  down and the right up turn the view clockwise, the tank turning left;
  the sticks apart bring up a target sight over the tank.
- The `.mra`s (all three) still assemble to the reference image
  (`ns2_mra.py --check`).

**On the board** (the standard bitstream with NS2-24): Assault (Rev B), a
game started from the d-pad and buttons: the d-pad's up drives the tank
forward (the ground moves past it), Turn Left turns the view and Turn
Right turns it back, Sticks Apart changes the tank's sprite as in MAME.

**Follow-up: both tracks on the left stick (reported after v2026-10-02).**
Main_MiSTer (`input.cpp`) sends a pad's analog sticks to the core only
when the pad's system mapping (its gamecontrollerdb entry or the main
menu's definition) marks the axes analog (`stick_l`, `stick_r`); it also
presses the d-pad from the left stick past `DPAD_THRESHOLD` (50% by
default). A pad without that mapping reaches the core as the d-pad alone:
the left stick pushed both tracks through the d-pad, and the right stick
did nothing. The virtual pad above has the firmware's Xbox mapping, so it
did not show this.
- The right stick can also be four buttons, B6-B9 (J1's Button 6-9, the
  `.mra`s' Right Up, Right Down, Right Left, Right Right): any input,
  the right stick's directions too, can be bound to them.
- A player who has used the right stick, analog or buttons, since the
  reset drives the left track with the left analog stick or the d-pad and
  the right track with the right stick. Before that the d-pad pushes both,
  as before, for a single-stick pad.
- `sim/rtl/ns2_controls`: 137 checks, all pass (the buttons alone and
  with the d-pad, both players, the latch, the turn buttons over it).
- On the board, Assault's own switch test (Service Mode), a virtual pad
  made as Linux's xpad driver makes an XInput pad (GP2040-CE's default
  mode, the reporter's FightBox R10 Dual's: 045e:028e v0114, axes X Y Z RX
  RY RZ and the hat, the gamecontrollerdb's Xbox 360 entry): each stick at
  30% (under MiSTer's 50% d-pad threshold, so the analog values alone) in
  each direction lights its own stick's switch only, both players; both at
  full drive both. The same on v2026-10-02 and with this change. (A first
  virtual pad with four axes shifted the database's axis numbers, and
  Main_MiSTer keeps a GUID's axis numbering until it restarts: its right
  stick came out wrong until the board was rebooted. A real pad reports
  all six.)

## NS2-24 — The SDRAM's address merged like its command (closed, measured)

After NS2-22 and NS2-23, one build in eight met timing: the misses were all
on clk_sd into `jtframe_sdram64`'s `sdram_a` (from the refresh's `help` and
`rfshing`, the latch's `noreq` and `rd_l`, a bank's `st`), through the
grant's priority mux, by 0.015 to 0.665 ns. The command had the same path
and was merged in NS2-21.

A local change, the same way: a bank (the download's `u_prog` too) drives
its address only with a command (0 with NOP, which the SDRAM ignores), and
no bank commands while another holds the grant or the refresh runs; the
refresh's address is A10 (its precharge-all). So `sdram_a` is the OR of the
banks', `u_prog`'s and the refresh's A10, but for init (a register). A12/A11
(MiSTer's DQM with the write mask ORed in) are the same as the mux's on
every clock; A10-A0 differ only on a NOP.

**Measured:**
- In simulation the merge is compared with the mux on every clock (A12/A11)
  and every command (all): Phelios (40 frames), Lucky & Wild (60), Metal
  Hawk's play (to frame 1030), 0 differences, the pictures as before, 0
  SDRAM violations.
- The builds: STD 5, MH 9 and SG 14 met every clock at once, clk_sd at
  +0.136, +0.160, +0.400 ns; LW at seed 33 met clk_sd with +0.329 ns (its
  miss was HDMI's).
- Seeds: STD 5, MH 9, SG 14, SZ 10, LW 34, every clock met, setup and hold
  (clk_sd +0.136, +0.160, +0.400, +0.490, +0.317 ns). SZ took five seeds
  (two missed HDMI or clk_sys); LW's 34 and 35 both met. On the board:
  Assault (above), Metal Hawk, Steel Gunner, Suzuka 8 Hours, Lucky & Wild.

## NS2-25 — The guns from the d-pad: Lucky & Wild's player 2 on a digital pad (closed, measured)

Lucky & Wild's second gun (AN3 X2, AN1 Y2, fire MCUH 4) took the second
pad's analog stick or a MiSTer gun only, so a player 2 with a digital pad
(a PlayStation Classic controller, say) or the keyboard could fire but not
aim. The same held for both players in the other gun games, player 1 having
the mouse besides.

Now each gun also aims from its pad's d-pad, 8 a frame (MAME's key delta
for the guns), staying where it is left; whichever moved last aims: the
stick (or gun), the d-pad, or for player 1 the mouse. A stick takes over
from the d-pad only when pushed past 12, so a resting analog stick's noise
does not snap the sight back. In Lucky & Wild player 1's d-pad is the wheel
and does not aim. Player 2's crosshair shows once its d-pad is used too.
The aim's state is cleared by a reset.

**Measured:** `sim/rtl/ns2_controls` (116 of 116): Lucky & Wild's player 2
d-pad steps AN3 and AN1 by 8 a frame and holds, its crosshair shows, it
fires, a resting stick keeps the d-pad's aim and a pushed one takes over,
and player 1's d-pad still steers without aiming; Golly! Ghost!'s player 1
d-pad aims, the mouse takes over, and the d-pad takes back from its own
position.

**On the board:** Lucky & Wild, two players from the keyboard (player 2 a
digital pad): player 2's d-pad took the game's second sight to the right
edge and the left, the core's yellow crosshair with it. Golly! Ghost!:
player 1's d-pad moved the sight left, up, then to the bottom right.
Seeds STD 6, MH 11, SG 14, SZ 10, LW 34, every clock met.

## NS2-26 — The audio against MAME, every set: the C140's compressed samples, the YM2151's writes, the gains, the C140's images (closed, measured)

**Reported:** a high-pitched screech in Rolling Thunder 2, and sound effects
missing in some games.

**The method** (`tools/ns2_audio_audit.py`, the MAME patch `NS2_SND_ISO` in
`tools/mame-patches`):
- MAME 0.289 records each set three ways from a cold boot: the stock mix,
  the YM2151 alone and the C140 alone, each at its own gain (mix = YM2151 +
  C140 to 1 LSB). The board's HDMI audio (the capture box, card 1) is
  recorded through the same schedule: the attract (125 s) and a played game
  (coin, Start, the fire button and stick for 80 s; `play.lua` in MAME, a
  uinput script on the MiSTer).
- The two timelines are aligned in 10 s windows by their band-energy
  envelopes; the board's band powers are fitted as gy^2 * YM2151 + gc^2 *
  C140, giving each chip's level against MAME's, and the board's spectrum
  is compared with the fitted prediction.
- The chips alone, in simulation, against MAME on identical input:
  `sim/rtl/ns2_c140` replays the sound CPU's C140 writes (all 28 parents,
  125 s of play each); `sim/rtl/ns2_ym` replays MAME's YM2151 writes through
  the core's path (ns2_ym_fifo and jt51) and compares with MAME's YM2151
  alone. A Python port of MAME's C140 loop matches MAME's samples exactly
  and locates a divergence to a voice.

**1. The C140's compressed samples (the missing sound effects).** `pcm()`
in `rtl/ns2_c140.sv` decodes a compressed byte as MAME's table, but its
mantissa's shift, `s1 + 3`, was 3 bits wide: for exponents 5-7 it shifted by
0-2 instead of 8-10, so the loud compressed samples lost their mantissa
(Assault, NS2-8's measured set, never uses those exponents). With MAME's
writes replayed for 125 s of play, Bubble Trouble's C140 differed from MAME
in 498,525 samples and ran 1.1 dB quiet (its worst 5 s, -9.8 dB of error);
Cosmo Gang 287,595 samples. The shift is now 4 bits. All 28 parents then
match MAME's C140 to 0.00 dB in level; the samples left different are a
register write on the clock of a sample edge, a voice a sample apart (Four
Trax's looping voice 7, its frequency's two bytes either side of an edge;
the board's edges are not MAME's anyway), not a sound.

**2. The YM2151's writes (missing and wrong FM sound).** jt51 applies an
operator or key-on write over the next 32 of its cycles (up to 64 with its
half-rate phase), and a write before that cancels or redirects it. The games
write every 26-28 cycles and never read the busy flag (Rolling Thunder 2:
22,230 writes and no status read in 20 s), while MAME's YM2151 takes every
write at once. Replaying MAME's YM2151 writes into jt51: Rolling Thunder 2's
FM went silent at 14.2 s and stayed so (-11.3 dB against MAME, envelope
correlation 0.54); Golly! Ghost! lost half its loud frames. `rtl/ns2_ym_fifo.sv`
queues the 6809's writes (512 deep, a block RAM) and passes them to jt51 64
YM cycles after the last data write (address after address at once): with
all the parents' logged writes the queue peaks at 236 (an init burst), a
write waits 2 ms at most, and every write leaves in order (Finest Hour: all
20,252 checked). `sim/rtl/ns2_ym` (the FIFO and jt51, at clk_sys, against
MAME's YM2151 alone):

| set | before: level, envelope corr. | after |
|---|---|---|
| Rolling Thunder 2 | -11.3 dB, 0.54 | -0.1 dB, 0.993 |
| Golly! Ghost! | -1.8 dB, 0.72 | +2.1 dB, 0.986 |
| Dirt Fox | -5.3 dB, 0.96 | +0.1 dB, 0.972 |
| Finest Hour | -4.5 dB, 0.99 | -0.2 dB, 0.999 |
| Steel Gunner 2 | -3.6 dB, 0.97 | -0.3 dB, 0.992 |
| Mirai Ninja | +0.2 dB, 0.97 | +0.8 dB, 0.993 |
| Super World Stadium | -0.7 dB, 0.95 | +0.0 dB, 0.984 |

(The testbench's reset must be held for many YM cycles: jt51 resets its slots
under its clock enable; on the board the download's reset is long.) jt51's
timbre still differs from MAME's on some instruments (Mirai Ninja's bass:
its fundamental against MAME's second harmonic, same notes, levels within
4%): open.

**3. The speaker gains (Rolling Thunder 2's loudness and the quiet sets).**
MAME's gains differ by machine config, and the core used the base's (C140
0.75, YM2151 0.80) for all: base3 (Burning Force, Dragon Saber, Rolling
Thunder 2, Valkyrie) is C140 0.45 and YM2151 1.0, so their C140 was 1.67x
MAME's (the board: 1.57-1.61 in C140-only frames, +3.6 to +5.8 dB overall,
Rolling Thunder 2 peaking at 26,362 against MAME's 16,430); base2 and
assaultp (Assault, Assault Plus, Dirt Fox, Finest Hour, Phelios) and Metal
Hawk are C140 1.0, so theirs was 0.75x (the board: 0.67-0.72). The gains are
now config bytes 36-37 (x128, `tools/ns2_romdata.py` GAINS), and every `.mra`
carries them; the top mixes by them (an image without them takes the
base's). With the base's sets the board's C140 measures 0.94-0.97 of MAME's
(the HDMI path).

**4. The C140's images (the high-pitched sound).** The C140's 21.333 kHz
samples, held, put images above its 10.67 kHz Nyquist; MAME's resampler
removes them. The board had, against MAME, +6 dB at 11 kHz, +12 at 14 kHz
and +24 at 18 kHz in every set (Rolling Thunder 2's 1.67x C140 made them
4.4 dB stronger still). `rtl/ns2_c140_fir.sv` (now `rtl/ns2_fir4.sv`, NS2-29) interpolates the C140 4x to
85.333 kHz through a 128-tap low-pass (`tools/ns2_firgen.py`: flat to 9
kHz, -42 dB at 11.3 kHz, -66 dB at 12 kHz), bit-exact against its integer
model over 1.6 M outputs (and its impulse response). On MAME's own C140
samples it takes the 11-14 kHz band from +5.8 to -30.7 dB and 14-18 kHz from
+15.1 to -52.0 dB against MAME, and leaves 0-9 kHz as it was.

**On the board** (seeds STD 7, MH 11, SG 15, SZ 17, LW 37, every clock met;
the `.mra`s with their gains): every parent recaptured, attract and play, and
fitted against MAME as before. Level is the board's total against MAME's mix
over the matched windows; C140 is its gain in the frames where MAME has the
C140 alone (the HDMI path's own is about 0.96); before -> after:

| set | attract level | attract C140 | play level | play C140 |
|---|---|---|---|---|
| Assault | -2.6 -> -0.1 dB | 0.72 -> 0.96 | -> -0.4 dB | -> 0.96 |
| Bubble Trouble | (silent) | | -> -0.1 dB | -> 0.97 |
| Burning Force | +3.7 -> -0.3 dB | 1.61 -> 0.98 | +3.6 -> -0.2 dB | 1.60 -> 0.99 |
| Cosmo Gang | -2.6 -> +0.2 dB | 0.67 -> 0.95 | -1.5 -> +0.4 dB | 0.81 -> 0.96 |
| Dirt Fox | -2.7 -> -0.2 dB | 0.72 -> 0.96 | -2.7 -> -0.0 dB | 0.70 -> 0.95 |
| Dragon Saber | +4.1 -> -0.0 dB | 1.61 -> 0.97 | +4.3 -> +1.0 dB | 1.74 -> 1.13 |
| Final Lap 2 | (silent) | | +0.8 -> +0.9 dB | 0.96 -> 0.97 |
| Final Lap 3 | (silent) | | +2.7 -> +3.0 dB | 1.27 -> 1.32 |
| Final Lap | (silent) | | -6.3 -> -5.8 dB | 0.45 -> 0.47 |
| Finest Hour | (silent) | | -2.9 -> -0.4 dB | 0.69 -> 0.92 |
| Four Trax | (silent) | | -1.5 -> -0.5 dB | 0.82 -> 0.94 |
| Golly! Ghost! | -1.2 -> +0.0 dB | 0.84 -> 0.93 | -0.4 -> +0.2 dB | 0.86 -> 0.92 |
| Kyuukai Douchuuki | (silent) | | -0.3 -> -0.6 dB | 0.90 -> 0.87 |
| Lucky & Wild | (silent) | | -0.9 -> -0.5 dB | 0.90 -> 0.94 |
| Marvel Land | -0.4 -> -0.3 dB | 0.94 -> 0.97 | -0.3 -> -0.4 dB | 0.88 -> 0.91 |
| Metal Hawk | -3.4 -> -0.4 dB | 0.67 -> 0.93 | -2.7 -> -0.2 dB | 0.72 -> 0.97 |
| Mirai Ninja | +0.2 -> -0.1 dB | 0.96 -> 0.97 | -0.5 -> -0.3 dB | 0.51 -> 0.56 |
| Ordyne | (silent) | | -1.9 -> -0.3 dB | 0.86 -> 0.96 |
| Phelios | -2.5 -> -0.2 dB | 0.72 -> 0.97 | -2.8 -> -0.3 dB | 0.70 -> 0.95 |
| Rolling Thunder 2 | +3.9 -> -0.3 dB | 1.57 -> 0.96 | +4.0 -> -0.0 dB | 1.73 -> 1.05 |
| Steel Gunner | -0.2 -> -0.1 dB | 0.96 -> 0.97 | -0.5 -> -0.4 dB | 0.95 -> 0.97 |
| Steel Gunner 2 | -0.4 -> -0.3 dB | 0.96 -> 0.96 | -0.2 -> -0.3 dB | 0.94 -> 0.94 |
| Suzuka 8 Hours 2 | (silent) | | -0.1 -> -0.1 dB | 0.97 -> 0.98 |
| Suzuka 8 Hours | (silent) | | -0.0 -> -0.0 dB | 0.99 -> 0.99 |
| Super World Stadium | -0.3 -> -0.3 dB | 0.96 -> 0.97 | -0.2 -> -0.1 dB | 0.95 -> 0.97 |
| Super World Stadium '92 | -0.3 -> -0.3 dB | 0.97 -> 0.97 | -0.3 -> -0.3 dB | 0.93 -> 0.92 |
| Super World Stadium '93 | -0.3 -> -0.2 dB | 0.97 -> 0.98 | -0.4 -> -0.3 dB | 0.92 -> 0.92 |
| Valkyrie no Densetsu | +4.3 -> +0.0 dB | 1.59 -> 1.00 | +5.8 -> +2.4 dB | 1.64 -> 1.10 |

("Silent": MAME's attract has no sound for that set, the board's neither.)
The play rows are rougher than the attract: the games diverge (fewer windows
match; Valkyrie 2 of 16), and the driving games take MAME's pedal held full
against the core's pedal ramped by a pulsed button, so Final Lap's and Final
Lap 3's engines run differently (their C140 in simulation equals MAME's).
In the frequency bands, the C140's images are gone: Assault 11/14/18 kHz
+6/+12/+25 dB -> -5/-13/-8 dB against MAME, Metal Hawk +6/+13/+25 ->
-4/-12/-10. What remains above 6 kHz, +2 to +7 dB in all, is the 9 kHz band
(+4 to +8 dB: the C140's filter is flat to 9 kHz where MAME's resampler
already falls) and, where the YM2151 plays (Burning Force: +4/+5/+9 dB at
11/14/18 kHz), jt51's 55.9 kHz output held into MiSTer's 48 kHz: open.

Cost: the C140's filter 2 DSPs and its history; the YM2151's FIFO 1 M10K
(LW: 41,489 ALMs (99%), 546 of 553 M10K).

## NS2-27 — The SDRAM's timing for the slower chips: CL3, a clock more of tRCD and tRP (closed, confirmed on other boards)

**Reported:** NS2-19's black screens and crashes, much rarer since its fixes,
still on some users' boards.

**Compared with the other kuzecores** (`sdram.sv`, no reports): the same I/O
settings (fast input and output registers, maximum current, 3.3-V LVTTL)
and refresh within the spec, but CL3 at 96 MHz where NamcoS2 ran CL2 at
98.304 MHz. CL2 at 10.17 ns a clock is at the edge of the -7 grade chips
some MiSTer SDRAM modules carry (CL2 needs tCK >= 10 ns there).

**Measured, every command interval.** `sdram_model_burst.sv` now keeps the
shortest interval it sees of each timing; M3 prints them (download, then
download and play). Phelios, Suzuka 8 Hours (work RAM in the SDRAM: writes)
and Lucky & Wild, before:

| | clocks | ns | the datasheets' minimum |
|---|---|---|---|
| tRCD (ACTIVE to READ/WRITE) | 2 | 20.3 | 15-18 (-6), 20-21 (-7) |
| tRP (PRECHARGE to ACTIVE) | 2 | 20.3 | 15-18 (-6), 20-21 (-7) |
| tRAS | 6 | 61.0 | 42 |
| tRC | 11 | 111.9 | 60-63 |
| tRRD | 3 | 30.5 | 12-14 |
| tWR (last write to PRECHARGE) | 4 | 40.7 | 2 clocks / 14 |
| tRFC (REF to the next command) | 7 | 71.2 | 60-66 |

Everything has margin but tRCD and tRP, at or under the -7 parts' minimum,
and CL2 itself. The model also now masks read data with DQM two clocks
after it is sampled (MiSTer wires DQML/DQMH to A11/A12, so an ACTIVE's
row bits mask a read word due then): the controller's windows are checked,
at either CAS latency.

**The change** (`jtframe_sdram64`, local parameters; `NamcoS2.sv` sets them):
- `CL=3`: the mode register, and each bank's `DST` (READ + CL). `in_busy`,
  which spaces two reads, stays counted from the READ: back-to-back reads
  every 4 clocks at either CL. The read capture's SDC is the same (the
  word is still taken on the second clk_sd edge after the chip's).
- `XRC=1`: a clock more of tRCD and tRP (30.5 ns), the refresh's PRECHARGE
  ALL too (its cycle a clock longer, tRFC as before).
- Timing: the command and address paths into the pins were clk_sd's worst
  and got worse. A bank now drives A10-A0 while it holds the grant (one
  bank at most; none while the refresh runs), chosen by its state, not by
  `do_*` (which wait on the other banks' dbusy/dqm/act). A12/A11 (MiSTer's
  DQM) stay on `do_act`.

**Measured:**
- `sim/rtl/sdram_probe`, 64-bit reads saturating all four banks, every
  word checked: 0 bad words, 0 violations, both arbitrations. Random rows
  12.59 -> 10.50 M/s (CL3 alone 11.80), sequential 15.68 -> 15.65.
- M3, before -> after (pictures exact as before in every run):

| set | pictures | busiest line (of 3,072 clocks) |
|---|---|---|
| Phelios attract | 20/20 | 2,734 -> 2,866 |
| Phelios play (`PLAY=500`, 800 frames) | the same frames | 2,820 -> 2,869 |
| Assault attract | 277/300 (as NS2-14) | 2,734 -> 2,866 |
| Metal Hawk play (`PLAY=900`, to 1,100) | the same frames | 2,535 -> 2,589 |
| Lucky & Wild attract | 53/60, the same frames | 2,155 -> 2,215 |
| Steel Gunner 2 attract | 53/60, the same frames | 1,974 -> 1,974 |
| Suzuka 8 Hours attract | 19/20 | 1,974 -> 1,974 |

  No overruns; the download takes 15% more clocks (under a second). The
  play runs' differing frames are the ones where the game already differs
  from MAME's capture; their pixel counts move a little, as the CPUs'
  waits change.
- Builds: STD seed 9, MH 12, SG 15, SZ 18, LW 45, every clock met (SZ and
  LW took several seeds; before the address change none of six met). On
  the board with these: Phelios, Assault (its switch test, NS2-23),
  Steel Gunner, Metal Hawk (its ROZ demo), Suzuka 8 Hours, Lucky & Wild; with the first CL3 builds
  (before the address change): Phelios, Assault, Rolling Thunder 2, Steel
  Gunner 2.

**Confirmed** (2026-10-03): the boards that still reported NS2-19's black
screens and crashes run correctly with v2026-10-02.2 and later (NS2-19's
refresh and clock phase, with this CL3 and the longer tRCD/tRP).

## NS2-28 — The games' button names, and Dirt Fox's gears on buttons (closed, measured)

**Reported (GitHub #5):** the sets on MAME's common ports showed "Button 1-3"
whatever the game uses, and Dirt Fox's gears were only on the d-pad's up
and down.

**Which buttons each game reads.** MAME's `base` ports give every one of
these sets three buttons; which the game reads is not in the driver. Each
was measured in MAME (0.289, `-nothrottle`, deterministic): coins and Start,
Button 1 tapped through the menus in every run, then one button held for 12
frames in play, its screens against the same run without the press (two
control runs identical). The others did nothing (0 pixels differ over the
next 90 frames):

| family | Button 1 | Button 2 | Button 3 |
|---|---|---|---|
| Cosmo Gang | Fire | - | - |
| Dragon Saber | Fire (the air shot) | Bomb | - |
| Marvel Land | Jump | - | - |
| Mirai Ninja | Throw | Jump | - |
| Ordyne | Shoot | Bomb | - |
| Phelios | Fire | - | - |
| Rolling Thunder 2 | Shoot | Jump | - |
| Valkyrie no Densetsu | Attack | Jump | - |

(A first pass by screen hashes over a whole run flagged more: a press also
skips a game's intro or rank select, or moves its random numbers. Cosmo
Gang's Button 2, held through a stage, scored nothing where Button 1 scored
4,670.) `tools/ns2_mra.py` names them per family (`FAMILY_BUTTONS`, the
parent and its clones), with "-" hiding the unread buttons from MiSTer's
mapping menu; the Valkyrie translation's `.mra` the same by hand.

**Dirt Fox:** MAME's ports put Gear Shift Down on the joystick's up (MCUB
5) and Gear Shift Up on its down (MCUB 7). Gear Up (Button 3) and Gear Down
(Button 4) now drive them too (`ns2_controls`, mode bit 5), the d-pad as
before. `sim/rtl/ns2_controls`: 140 checks, all pass. On the board (the
standard bitstream, seed 11), Dirt Fox's test mode moves its option value
the same way with Gear Down (B4) as with the d-pad's up, and with Gear Up
(B3) as with its down.

## NS2-29 — The audio's last differences against MAME: the YM2151's high frequencies, the C140's 9 kHz, jt51's timbre (closed, measured)

**Open from NS2-26:** above 6 kHz the board was +2 to +7 dB against MAME:
the 9 kHz band (+4 to +8 dB) and, where the YM2151 plays, 11-18 kHz (+4 to
+9 dB); and jt51's timbre seemed to differ on some instruments (Mirai
Ninja's bass).

**MAME's response, exactly.** MAME 0.289's default resampler is
`audio_resampler_lofi` (`emu/resampler.cpp`): a source faster than the
48 kHz output is first averaged `1 + fs / 48000` samples at a time (the
YM2151's 55.93 kHz: pairs, to 27.97 kHz), then a 4-point cubic
interpolates. As a frequency response: the YM2151 -3.3 dB at 9.5 kHz, -15
dB at 16 kHz, -52 dB at 23 kHz; the C140 (21.333 kHz, no averaging) -2.2
dB at 7.5 kHz, -4.9 dB at 9.5 kHz. Measured, MAME's YM2151 against its own
ymfm at 55.93 kHz follows this to 8 kHz; above, MAME is higher than the
model, by its own aliasing (the averaging folds 14-28 kHz down).

The core held jt51's 55.93 kHz samples into MiSTer's 48 kHz output (no
filter: everything above 24 kHz folded back), and the C140's interpolator
(NS2-26) was flat to 9 kHz.

**The fix.** `rtl/ns2_fir4.sv` (the C140's interpolator, generalised: a
parameter picks the chip's coefficients and its phase spacing) now filters
both chips, 4x, 128 taps; `tools/ns2_firgen.py` designs both (weighted least
squares, the passband MAME's lofi response, then a stopband: MAME's own
images and aliasing are not copied):
- YM2151 (jt51's sample's edge, every 878-879 clocks; phases 219 clocks
  apart): MAME's curve within 0.1 dB to 23 kHz, below -100 dB from 27.97
  kHz.
- C140: MAME's curve within 0.1 dB to 9.5 kHz, -8.6 dB at 10 kHz, -51 dB
  at 11.3 kHz, below -84 dB from 12 kHz (before: flat to 9 kHz, -42 dB at
  11.3 kHz).
`sim/rtl/ns2_fir` checks the RTL against its integer model with the
board's strobes (jt51's with random extra gaps): 4,000,000 YM2151 outputs
(Mirai Ninja's jt51) and 1,600,000 C140 outputs (Assault's C140), 0 differ.
Cost: 2 DSPs and a history; Lucky & Wild 41,497 of 41,910 ALMs. Seeds STD
12, MH 13, SG 15, SZ 19, LW 51, every clock met (STD, MH, SZ and LW each
missed HDMI or clk_sd by 0.02-0.25 ns on their old seeds).

**On the board**, every parent recaptured as NS2-26 (the attract, or a
played game where MAME's attract is silent), fitted against MAME the same
way. Level is unchanged in every set (within 0.6 dB of before). The high
frequencies, before -> after (the audit's HF excess; third-octave bands
against MAME):

| set | HF excess | 9.0 kHz | 11.3 kHz | 14.3 kHz |
|---|---|---|---|---|
| Burning Force (YM2151 10%) | +2.9 -> +1.4 dB | | +3.6 -> +0.4 | +5.2 -> -2.8 |
| Mirai Ninja (YM2151 33%) | +4.1 -> +0.9 dB | | +3.7 -> -1.0 | +6.8 -> -2.8 |
| Ordyne, play (YM2151 33%) | +4.2 -> +2.4 dB | +2.2 -> -0.6 | -0.5 -> -5.1 | -1.0 -> -9.3 |
| Marvel Land | +2.5 -> +0.8 dB | | +3.3 -> -0.8 | +5.2 -> -3.5 |
| Phelios | +3.0 -> +0.5 dB | | +2.1 -> -2.4 | +4.8 -> -3.8 |
| Steel Gunner | +3.1 -> +1.2 dB | +5.3 -> +1.3 | -3.4 -> -9.2 | -8.4 -> -15.2 |
| Metal Hawk | +3.1 -> +1.1 dB | +4.9 -> +1.5 | -3.6 -> -8.2 | -12.1 -> -12.2 |
| Suzuka 8 Hours, play | +4.0 -> +1.9 dB | +7.0 -> +3.9 | -1.8 -> -6.4 | -7.7 -> -8.9 |
| Finest Hour, play | +4.8 -> +2.7 dB | +7.1 -> +3.3 | -1.3 -> -6.1 | -4.7 -> -6.8 |

| Lucky & Wild, play | +4.3 -> +1.8 dB | +5.3 -> +1.8 | +1.0 -> -3.3 | +4.3 -> -3.0 |

In all 28 the HF excess falls by 1.5 to 3.2 dB, to -0.4 to +2.7 dB, but
for Cosmo Gang (+4.2: its fit is 8 dB off before and after, its alignment)
and Final Lap's play (+4.2: the pedal, below). Where the C140 dominates, the board is now below MAME above 11
kHz: MAME's cubic leaves part of the C140's images there, which the filter
removes. (The play captures' levels are as NS2-26's: the driving games'
pedals.)

**jt51's timbre: no defect.** `tools/ym_ref` renders a write log through
MAME's own YM2151 (ymfm, from MAME's tree; `fifo_time.py` re-times a log as
`ns2_ym_fifo` passes it):
- Eight sets' logs (125 s each) through jt51 (`sim/rtl/ns2_ym`) against
  ymfm, second by second: level -0.03 to -0.65 dB, spectral shape within
  0.1-1.3 dB (median), 5 of 351 active seconds past 3 dB.
- Mirai Ninja, each channel alone (`chsplit.py`): every second matches.
  The seconds that differ in the mix are transients where the game
  rewrites a voice mid-note (jt51 applies a write over 32 of its cycles,
  ymfm at once: channel 4 at 40.48 s, 50 ms) or the FIFO's timing across
  channels. NS2-26's "bass an octave off" was a whole-window comparison
  against MAME's recording, not the same writes.
- Against Nuked-OPM (a transistor-level YM2151, used as a reference only):
  one note for every algorithm and feedback (64 patches), the first 10
  harmonics. jt51's median worst error 0.4 dB, ymfm's 0.3; within 3 dB on
  every harmonic jt51 52 of 64, ymfm 47. jt51's misses are weak harmonics
  the chip notches to -31 to -41 dB (jt51 -23 to -30: algorithm 3 with
  feedback 0-2) and algorithm 0 at feedback 7; ymfm's are elsewhere
  (algorithms 1-2).

## NS2-30 — Pause, autofire, high scores and cheats (closed; Suzuka 8 Hours and Lucky & Wild: NS2-33)

**Pause** (OSD: Pause; Pause when OSD is open): `ns2_board`'s `pause` stops
every CPU through the lockstep's hold (NS2-14), and with them the sound
chips: the YM2151's clock enable, the C140's sample tick and timer
(`ns2_c140`'s `hold`) and the 6809's 120 Hz timer. The video keeps scanning
the frozen RAM. On the board (Steel Gunner): two captures 3 s apart are the
same with Pause on, and the game runs on when it is off. Phelios in play
(STD s15, Pause when OSD is open, HDMI audio recorded): the stage music at
2,000-3,000 RMS, then exactly 0 and the picture still for the 10 s the OSD
is open, then the music back at its level and the game moving within
0.5 s of the OSD closing (the ship then lost, with no input, to game over
and the title: the game ran on).

**Autofire** (OSD: Button 1, Button 2 or both; 15, 10, 7.5 or 30 Hz): a held
button is let through half of each period, counted in the board's frames
(none in a pause), both players, the keyboard's too. On the board, Assault's
switch test (Player 1 FIRE, Left Ctrl held 3 s, captured at 60 fps): Off,
lit every frame; Button 1 at 15 Hz, two frames lit and two dark; at 30 Hz,
one and one; Button 2 only, Button 1 lit every frame.

**The back door.** `ns2_board`'s `hb_*` port: a request stops the CPUs (as
the hold, the sound running); 8 clocks later (the shared bus's last access
done) `hb_ok`, and the port owns the master's work RAM (a second use of its
port, `ns2_cpu`) and the C123's RAM (the video's CPU port) at the master's
byte addresses: 100000-10ffff and 400000-41ffff, data a clock after the
address. Not with the work RAM in the SDRAM (Suzuka 8 Hours, Lucky & Wild):
those bitstreams leave out the hiscore and cheat modules and hide their
page. `sim/rtl/ns2_frames` `HB_TEST=F`: in Assault's frame 40 the back door
stopped the CPUs 200 clocks, read and wrote back 32 bytes (the C123's
against its RAM array), 0 failures, and the 81 pictures after it are the
run's without it, frame for frame.

**High scores.** MAME's `hiscore.dat` has 35 of the 61 sets: their tables
are in RAM, not in the EEPROM (D6 assumed the EEPROM held them all). The
MiSTer hiscore module (`rtl/third_party/hiscore`) restores and saves them:
- The `.nvm` (index 4) is the EEPROM and then the dump (at 0x2000); an
  EEPROM-only `.nvm` still loads. `<nvram>` grows by the dump's length.
- `hps_io` is 16 bits wide and hiscore.v takes bytes: the top's byte stream
  splits each word written into two byte writes, and an upload reads two
  bytes on alternate clocks. hiscore.v's upload data is two clocks after its
  address (`data_addr` registered, then its RAM): taken a clock early, the
  first save was the table shifted a byte (found against MAME's RAM).
- hiscore.v follows the upload's address only while it sees the upload:
  told of it from 0x2000 on, the dump's first byte went out stale (Steel
  Gunner's 0xcc, Steel Gunner 2's 0xed against MAME's 0x00), and the next
  load's validation would have discarded the saved table. It now sees the
  whole `.nvm` upload, its address held at 0 through the EEPROM's part.
- hiscore.v waits ACCESS_PAUSEPAD clocks after its `pause_cpu` before it
  reads or writes; the back door is ready 8 clocks after the request
  (`hb_ok`). At the header's 2, the restore's checks read the RAM before the
  back door had it: Steel Gunner 2 never restored (an edited "TEST" stayed
  "GORO"; MAME's plugin restores the same dump). The header's
  ACCESS_PAUSEPAD is now 16.
- `tools/ns2_extras.py` writes `<rom index="3">` (16-byte header, START_WAIT
  10 s, past the boards' RAM tests; a record a hiscore.dat line) for 33 sets
  (not Lucky & Wild's two).
- On the board: Steel Gunner's first save is MAME's table, byte for byte;
  Phelios, with an 8 KB EEPROM `.nvm`, saved 8,282 bytes (scores 50000-7650,
  the start and end checks as hiscore.dat's), and with its first entry
  edited to "TEST 99920" the attract's ranking shows it after a reload. (An
  edit that breaks an entry's first or last byte discards the dump, by
  NMK16's validation in hiscore.v.) Steel Gunner 2, its first entry edited
  from "GORO" to "TEST", shows "1 TEST 10000" in "TODAY'S BEST GUYS" with
  ACCESS_PAUSEPAD 16.

**Cheats** (Pugsy's MAME cheat database, `rtl/cheats.sv` from the author's
other cores): ten fixed slots, each the set's first cheat named in its list
(`tools/ns2_extras.py` ALIASES: Infinite Time, Infinite Credits, P1/P2
Invincibility, P1/P2 Infinite Lives, P1/P2 Infinite Energy, Maximum Speed,
P1 Infinite Weapons), a cheat taken only if every action is a plain or masked
write the back door reaches; 49 sets have at least one. A slot the set has
not is hidden (menumask).
- Local changes: the walk waits for `paused` (the back door's 8 clocks); the
  enable bit is indexed by the whole slot number (3 bits before, fine at 7
  slots); the table is a block RAM read a byte at a time (in registers it
  took 1,613 ALMs at ten slots and the standard bitstream no longer fitted).
- `sim/rtl/cheats`: with five sets' tables, every slot on, one frame's
  writes equal the table's actions, and the pause is released.
- On the board: Steel Gunner's page shows its six slots only; Infinite
  Credits gives player 1 nine credits with no coin.

**Cost:** the standard bitstream 38,052 ALMs (91%, 37,251 before); Lucky &
Wild, with pause and autofire only, 41,534 (99%; seed 51 no longer fitted,
by a LAB).

## NS2-31 — The last picture differences against MAME: Suzuka 8 Hours, Lucky & Wild, Final Lap (closed, measured)

**Open from M2:** against MAME's pictures, M2 matched Suzuka 8 Hours 661 of
700, Lucky & Wild 289 and Final Lap 39 (its ranking row cycling at another
phase); the replay (NS2-10) matched Suzuka 667 and Lucky & Wild 643 of 699.

**Measured again** (the current RTL, M2 from power-on, `PICS_DUMP`, then
`tools/ns2_replay.py`): the pictures are as before. Against the replay no
line differs anywhere without a write between its fetch and the end of its
output; every non-exact frame is such a line. `ns2_replay.py --either` now
also takes the state with every write up to the end of the line's output
(the board shows the old value or the new one):

| set | replay, exact frames | lines that equal the later state | lines with no write in their window that differ |
|---|---|---|---|
| Suzuka 8 Hours | 667 -> 675 of 699 | 8 | 0 |
| Lucky & Wild | 643 -> 644 of 699 | 47 | 0 |
| Final Lap (frames 200-229, 500-529, 640-669) | 90 of 90 | | 0 |

The lines left (Suzuka's in frames 39-66, lines 63-71; Lucky & Wild's in
95-105, lines 26-32) take a write inside their own fetch: part of the line
drawn from before it, part after. Final Lap's difference from MAME's
pictures is MAME's band drawing (NS2-2): its ranking screen's palette
cycles by writes during the frame, and the board shows each as the raster
meets it (frame 300: row 3's highlight and the dot-matrix title). The full
Final Lap replay takes about four minutes a frame (the road's model); the
three samples took it a quarter of the way.

## NS2-32 — Savestates (closed: every bitstream)

Alt+F1-F4 save, F1-F4 load (or the OSD's Savestates page): four slots a
set, persisted by the firmware (`savestates/Arcade/<set>_<n>.ss`, 743,432
bytes). The design and the image's map are in docs/savestates.md; in short:

- The engine and the parks are Arcade-GingaNin_MiSTer's. The 68000s and
  the 6809 park in monitors (a level-7 interrupt, an NMI); the MCU's every
  flop is in the image (the C65's 11 words, the C68's 25: the M740's
  through tools/ns2_740gen.py and the generated core alike, the generator's
  output not being reproducible, its state numbering varies by run).
- The machine freezes at one point of every CPU's phases (both 68000s
  waiting on RESUME, the 6809 fetching its loop on a falling E: the sound
  board's phase is now reset with the 68000s', as theirs always was) and
  the line events, the C140, the 120 Hz timer and the YM2151's clock stop
  until the release at a VBLANK, so a load resumes from exactly the state
  its save left, everything the image does not hold included.
- The C140's register file is now a block RAM (the 6809 holds its address
  for the whole E cycle): 4,096 flops and their 512-way mux, about 2,400
  registers and 1,900 ALMs off every bitstream. Its voices' state goes in
  and out through its write queue (direct writes doubled it to 9,800 ALMs).
- The YM2151 is restored from a shadow of its registers, written back
  through its FIFO on a clock of its own; its notes restart.
- The engine's own release raised `ss_resume` for a clock at the transfer's
  end, which let the CPUs go wherever the raster was (the first gate run's
  68000 traces); it now only raises it at the VBLANK (savestate.sv,
  marked). The flip buffer and the engine share DDR without interleaving
  (`ddr_pending`).

The gate (sim/rtl/ns2_ss, GingaNin's): save slot 0 in frame 400, slot 1
60 frames after it resumes; load slot 0, save slot 2 60 frames after that
resumes. Slots 1 and 2 equal word for word (742 KB, the YM's shadow
included), the 60 frames after each resume equal (the picture and both
68000s', the 6809's and the MCU's accesses), and the 68000s' first 40,000
accesses at the same clocks. PASS on Phelios, Assault, Rolling Thunder 2
(the standard board, the key's handshake), Final Lap, Final Lap 3 (the C68),
Metal Hawk (the C169) and Steel Gunner 2 (the C355, the C68). M2's pictures
without a savestate are the committed RTL's exactly (Phelios, 602 frames).

On the board (STD seed 115, MH 214, SG 216): Phelios, Steel Gunner 2 and
Metal Hawk, each saved in play and loaded 12 s later: the frames after the
load are the frames after the save (a steady offset, the capture's noise
only), until an input made after the save; the music resumes. A slot loads
after the core is reloaded (from the SD card). Suzuka 8 Hours and Lucky &
Wild (SZ 221, LW 256) still boot and run their demos.

Builds: STD 92% ALMs, MH 98%, SG 98%, SZ 88%, LW 89% (the C140's RAM gave
Lucky & Wild 4,300 ALMs back); every clock met.

**Suzuka 8 Hours and Lucky & Wild** (their work RAMs and the C139's RAM in
the SDRAM behind small caches, NS2-15):

- The engine shakes hands for each word on those bitstreams (`VARLAT`); the
  three RAMs go through their caches' CPU side (a read waits for its line,
  a write for room in the FIFO), the other regions answer in 5 clocks.
- A cache miss stops every CPU, so the caches' contents set the CPUs'
  timing against the video: all three are emptied as the transfer ends
  (`flush`), after a save and after its load alike.
- Every set those bitstreams serve has the C68, so they leave out the C65
  (`HAS_C65`): Lucky & Wild, with the engine, was 26 LABs over without it,
  and is at 99% with it out.
- The gate (`make WRAM=1`: the SDRAM's model, no C65): PASS on Suzuka 8
  Hours, Suzuka 8 Hours 2 and Lucky & Wild. On the board (SZ seed 324, LW
  358): saved in the demo and loaded 12 s later, the frames after the load
  are the frames after the save (Lucky & Wild: the timer, the hits, the
  ranking). The standard (315) and Steel Gunner (316) builds with the
  handshake's logic, again on the board: Phelios and Steel Gunner 2 as
  before.

Open: M3's exactness (the ROMs' caches change the lockstep's stops, so a
load matches its save as the board does).

## NS2-33 — High scores and cheats on Suzuka 8 Hours and Lucky & Wild (closed)

Their work RAMs are in the SDRAM behind small caches (NS2-15), and the
back door (NS2-30) reached only the block RAM, so the two bitstreams had
neither. Now:

- `ns2_cpu`'s back door goes through the work RAM's cache. It reads the
  address its user presented at the last clock the user ran (`hb_cap`), so
  a hit's byte is there a clock later, as the block RAM's was; a write
  waits a clock with its address (so a line present takes it too) and for
  room in the FIFO. While neither is ready, `hb_stall` holds the user:
  hiscore.v and cheats.sv have a `stall` input (marked) that holds their
  game RAM side (hiscore.v: its state machine, timer and the dump's writes;
  its HPS side runs on). The C123's RAM is the video port's, as before.
- `tools/ns2_mra.py` gives every set its blocks: Lucky & Wild and its
  Japanese set their high scores (`hiscore.dat`'s one entry, 160 bytes at
  100b00: the `.nvm` 8,352 bytes) and all four Suzuka 8 Hours and Lucky &
  Wild sets Infinite Time (107156). The Suzuka sets have no `hiscore.dat`
  entry. 35 sets have high scores now, 55 a cheat.
- hiscore.v is sized for the sets on each bitstream: on SZ and LW two
  entries of 256 bytes (Lucky & Wild's one of 160).
- Room: the modules are about 780 ALMs (hiscore 687, the cheats 93).
  Lucky & Wild was then 50 LABs over; it leaves out ALSA (Linux's audio
  into the core's output, `MISTER_DISABLE_ALSA`) and the HDMI scaler's
  adaptive filter (`MISTER_DISABLE_ADAPTIVE`), which also closed its HDMI
  clock's timing (seeds without it fit, or met timing, but not both).
  Suzuka 8 Hours keeps both (seed 427 met timing).
  The OSD's Autofire / Gun crosshair rules (NS2-34) took Lucky & Wild 13-19
  LABs over again: it also leaves out the scandoubler's HQ2x (its blender
  and difference checks, about 400 ALMs), its Scandoubler Fx list None and
  the CRT levels.
- Test: M2's back door test (`HB_TEST`, sim/rtl/ns2_frames, `WRAM=1`: the
  SDRAM's model) reads 16 bytes of the work RAM and 16 of the C123's RAM
  against the arrays, writes each changed and back with a read-back, and
  checks each change reached the SDRAM's model: 0 failures (Suzuka 8 Hours,
  and Phelios on the block RAM).
- On the board (LW seed 464): Lucky & Wild's first save is the ranking's
  ten records (TATSSIGE first, the start and end bytes hiscore.dat's), and
  with the first name edited to TESTSIGE the attract's ranking shows it
  after a reload. Infinite Time holds the demo's timer at 499 (it counts
  down from 149 without it).

## NS2-34 — The OSD shows only the options a set uses (closed)

- **Autofire** and **Autofire rate** are hidden (CONF_STR `h1`, menumask 1)
  unless the `.mra` turns them on: its configuration block's byte 38 bit 0
  (`af_unlock`). The `.mra` files in `releases/` leave it 0;
  `tools/ns2_autofire_mra.py` writes `autofire_releases/` (git-ignored: the
  same layout, names and `_alternatives/`, that one bit set). A saved
  Autofire setting does nothing while the options are hidden. The flag is in
  the ROM download's configuration, not in `<switches>`, so a saved
  `config/dips/<name>.dip` cannot hide it again (Arcade-NMK16_MiSTer's
  caveat, where the flag is a switch bit).
- **Gun crosshair** shows (`hD`, menumask 13) for the sets whose `.mra`'s
  control mode has light guns (ns2_controls' `guns`: Golly! Ghost!, Bubble
  Trouble, Steel Gunner 1 and 2, Lucky & Wild).
- **Aspect ratio**, **Scandoubler Fx** (`HB`) and **Orientation** (`H0`)
  were already hidden under direct video.
