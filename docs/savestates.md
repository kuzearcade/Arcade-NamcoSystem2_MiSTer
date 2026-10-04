# Savestates (M5)

MiSTer's savestate framework, as the author's other cores use it
(`rtl/savestate/` from Arcade-GingaNin_MiSTer): four slots in DDR, Alt+F1-F4
save and F1-F4 load (or the OSD's Savestates page), the firmware persisting
a slot when its counter changes. The engine (`savestate.sv`) and the CPU
parks are GingaNin's with three marked changes (below); everything around
them is this board's.

Every bitstream has them. On Suzuka 8 Hours and Lucky & Wild the 68000s'
work RAMs and the C139's RAM are in the SDRAM behind small caches (NS2-15):
the snapshot goes through the caches (below), and those two bitstreams
leave out the C65, which none of their sets has (`HAS_C65`), to make room.

## What a state is

The machine stopped at one fixed point, its memories and every register
that the CPUs can see the effect of. The video's per-line state (line
buffers, the C123's slot banks, the C355's sprite records, the tile and mask
caches) is rebuilt from the RAMs within two frames and is not saved; a load
waits those two frames before it lets the machine go.

The image, 16-bit words (ns2_board's map, 0x5ac00 words, 742 KB; slots of
1 MB at 0x3E000000):

| words | part | how |
|---|---|---|
| 00000 | master work RAM (32 K) | its port (the back door's) |
| 08000 | slave work RAM (32 K) | its port |
| 10000 | C123 RAM (32 K) | the video's CPU port |
| 18000 | C116: palette and registers (32 K) | the video's CPU port (registers 6-7 read as they are) |
| 20000 | ROZ / road RAM (64 K) | the video's CPU port |
| 30000 | C169 RAM (32 K) | the video's CPU port |
| 40000 | C355 RAM (0xa100) | the video's CPU port (its page-0 copy off) |
| 50000 | sprite RAM (8 K) | the video's CPU port |
| 52000 | C139 RAM (8 K) | its port |
| 54000 | EEPROM (8 K bytes) | its NVRAM port |
| 56000 | DPRAM (2 K bytes) | the 68000s' port |
| 58000 | sound RAM (8 K bytes) | its port |
| 5a000 | C140 registers (512 bytes) | the CPU's port (raw reads) |
| 5a200 | YM2151 register shadow (256 bytes) | its own RAM |
| 5a300 | the video's registers (C123, gfx_ctrl, ROZ, C169, C355) | the video's CPU port |
| 5a380 | registers: each 68000's SSP, USP and C148; the key; the sound board's; the MCUs' | register banks |
| 5a400 | C65 RAM / 5a600 C68 RAM | their ports |
| 5a800 | C140 voices (24 x 32 bytes) | through its write queue |

A region a bitstream does not have reads 0.

## The CPUs

- **68000s:** `ss_m68k_park`: a level-7 request; the vector substituted with
  a monitor at 0x5f8000 (unmapped on every board), served by `ns2_cpu` as a
  local device (never on the shared bus, never through the ROM's cache); the
  registers pushed onto the game's own stack (so into the work RAM's image),
  SSP and USP in the park's registers. The monitor's read of RESUME waits
  for its DTACK until the release (that CPU only, not the lockstep).
- **6809:** `ss_m6809_park`: NMI (the board has no other), its monitor at
  a000 (the amplifier's window: writes ignored, reads free).
- **MCU:** this core's own RTL (`ns2_hd63705*`, `ns2_m740`): every flop is
  in the image (the C65 11 words, the C68 25), so it stops wherever it is.
- **Reset:** a CPU the master's C148 holds in reset does not park (a save).
  A load lets every CPU out (they run from their reset vectors to park, and
  the MCU's flops can be written) until the image is in; its C148s then say
  who runs.

## The freeze

The save and its load must resume from the same state, everything the image
does not hold included. So the machine stops at one point of every CPU's
phases: both 68000s have waited 32 running clocks on RESUME (the wait loop
of the bus cycle, not its first states) and the 6809 fetches its monitor's
loop on a falling E (or a falling E while it is in reset); the 68000s'
phases and the 6809's are reset together, so theirs are then 0. From there
until the release:

- every CPU's phase stops (the lockstep's stop);
- the line events (VBLANK, POSIRQ, the MCU's line 200) are not made;
- the C140's tick and timer, the 120 Hz timer and the YM2151's clock stop
  (the OSD's pause); the C140's engine first empties its queue
  (`ss_frozen` waits for it).

The release is at a VBLANK's start, after one (a save) or three (a load)
edges, for every operation: the engine raised `ss_resume` for a clock
whenever it entered its release state (GingaNin's), which let the CPUs go at
the transfer's end, wherever the raster was; that pulse is gone (the first
gate run found it). The DPRAM's port B alternation starts over at the release.

## The sound chips

- **C140:** this core's RTL. The register file is read and written raw. A
  voice register write is also queued as the CPU's (the engine's copies:
  with the queue empty they are equal); the voices' running state (offset,
  position, key, the last two samples, mode, bank, start, end, loop) goes
  in and out a byte at a time through the same queue (a new kind of entry),
  so the arrays gain no write port. (Direct writes doubled the C140 to
  9,800 ALMs.)
- **YM2151 (jt51):** its operators live in shift registers. A shadow of
  every data write (0x19's AMD and PMD apart, each channel's key-on) is
  saved; a load empties the YM's FIFO and writes the shadow back through it
  (0x20-0xff, the noise, LFO, CT/W, the timers and their control, then the
  key-ons), on a clock of its own (the board's YM clock is held and in the
  image). Its sound restarts from the registers: a few ms of envelope differ.

## The work RAMs in the SDRAM (Suzuka 8 Hours, Lucky & Wild)

The engine shakes hands for every word (`VARLAT`, as Arcade-NMKBP964's):
`ss_rd` asks, `ss_ack` answers. The work RAMs and the C139's RAM go through
their caches' CPU side: a read waits for its line (a miss fills it from the
SDRAM), a write waits for room in the write FIFO. Every other region answers
in 5 clocks. A cache miss stops every CPU (the lockstep), so what the caches
hold changes the CPUs' timing against the video: all three are emptied as
the transfer ends, after a save and after a load alike, and the machine
resumes with the same, empty, caches.

## The DDR port

Three users: screen_rotate (writes), the in-core flip (ns2_flipbuf, bursts),
the engine (a word at a time, CLK_VIDEO). The engine goes only while
screen_rotate is not writing and the flip buffer is between transfers, and
the flip buffer starts none while the engine has a request waiting or in
flight (`ddr_pending`), so their reads never interleave.

## The gate (sim/rtl/ns2_ss)

GingaNin's: from power-on (M2's board, ROMs as arrays), save slot 0 in frame
T; K frames after it resumes save slot 1; load slot 0 and, K frames after
that resumes, save slot 2. Slots 1 and 2 must be equal word for word, and
each of the K frames after the load must equal its frame after the save:
the picture and both 68000s', the 6809's and the MCU's accesses (hashed per
frame), and (SS_TRACE) the 68000s' first accesses at the same clocks.

## Not yet

- M3 (the SDRAM, the ROMs' caches): the caches' contents change the
  lockstep's stops, so a load matches its save as the board does, not clock
  for clock.
