# Savestates: the design (M5, not built yet)

MiSTer's savestate framework, as the author's other cores use it
(`rtl/savestate/` from Arcade-GingaNin_MiSTer): four slots in DDR, Alt+F1-F4
save and F1-F4 load, the firmware persisting a slot when its counter
changes. The engine (`savestate.sv`) is reused as it is; what this board
needs is everything around it.

## What a state is

Every CPU parked at an instruction boundary, at the start of vblank, and
the board's memories and registers. Taken at vblank, the video's per-line
state (line buffers, the C123's slot banks, the C355's derived sprite
tables, the tile and mask caches) is rebuilt in the next frame and is not
saved; the ROM and work-RAM caches are emptied on a load.

| part | words (16-bit) | how |
|---|---|---|
| master work RAM | 32 K | its port (the back door's, NS2-30) |
| slave work RAM | 32 K | its port, as the master's |
| EEPROM | 4 K | its NVRAM port |
| DPRAM (2 KB, a byte a word) | 2 K | port B |
| C139 RAM | 8 K | its port |
| C123 tilemap RAM | 32 K | the video's CPU port (the back door's) |
| C116 palette (R, G, B, registers) | 16 K | the video's CPU port |
| sprite RAM (standard) / C355 (NB) | 8 K / 41 K | the video's CPU port |
| ROZ RAM (standard) / C169 RAM | 64 K / 32 K | the video's CPU port |
| C45 road RAM (Final Lap, Suzuka, Lucky & Wild) | in the ROZ's RAM | as the ROZ |
| video registers (C123, C116, ROZ, C169, C355, gfx_ctrl) | < 128 | a register bank |
| sound CPU RAM (8 KB) | 4 K | port |
| C140 (registers, 24 voices' state, the timer) | ~ 600 | a register bank (this core's RTL) |
| YM2151 | 256 (shadow) | replayed on a load (below) |
| MCU (HD63705 or M37450) RAM and registers | < 512 | a register bank (this core's RTL) |
| C148 x 3, the key custom, the timers, the inputs' state | < 64 | registers |
| CPU registers: 68000 x 2 (SSP, USP), 6809 | 8 | the park monitors' |

About 270 K words (540 KB) on the standard bitstream: slots of 1 MB at
0x3E000000 (`SLOT_STRIDE` 0x20000 words of 8 bytes). With the work RAM in
the SDRAM (Suzuka 8 Hours, Lucky & Wild) the work RAMs and the C139's are
read through their caches (`VARLAT` 1: a word a handshake).

## The CPUs

- **68000s:** `ss_m68k_park` (verbatim from GingaNin): a level-7 request,
  the vector substituted with a monitor at an unmapped address (0x5F8000 is
  free in every board's map), the registers pushed onto the game's own
  stack (so into the work RAM image), SSP and USP in the park's registers.
  The C148s' IPL is ORed with the park's.
- **6809:** `ss_m6809_park` (verbatim): the same with an NMI.
- **MCU:** both are this core's own RTL (`ns2_hd63705*`, `ns2_m740`), so
  they are stopped at an instruction boundary by their clock enable and
  their registers read and written directly: no monitor.
- The lockstep (NS2-14) already stops every CPU together; the park waits
  for each 68000 and the 6809 to reach their monitors, then holds the
  lockstep for the transfer.

## The sound chips

- **C140:** this core's RTL: the 24 voices' position, fraction, last
  samples and key state are registers, so saved exactly.
- **YM2151 (jt51):** its operator state lives in shift registers that
  cannot be read out cheaply. As the other cores do, a shadow of every
  register written (256 bytes) is saved, and a load writes them back
  through the FIFO (`ss_replay`): the voices restart from their registers,
  a few ms of FM envelope differ from the saved moment. Key-on state is
  replayed last.

## Verification (the gate)

In `sim/rtl/ns2_frames` (M2) and `sim/rtl/ns2_hw` (M3, through the SDRAM):
run a set to frame N, save; reset a fresh board, load; run both to frame
N + 300; the pictures must be equal frame for frame, and the CPUs' bus
traces equal access for access (but the YM2151, compared by level). Every
board: Assault, Final Lap, Metal Hawk, Steel Gunner 2, Suzuka 8 Hours,
Lucky & Wild. Then on the board, save and load in play.

## Cost

The engine and the parks are about 1,500 ALMs in the other cores; each RAM
port's mux and the register banks add to it. Lucky & Wild has 400 ALMs and
6 M10K left (NS2-30): it will need room made first (the C169's caches, the
CRT V-Size ring), or savestates on the other four bitstreams first.

## The order of the work

1. The snapshot bus in `ns2_board`, every RAM and register bank on it, with
   a simulation that reads and writes the whole image (no parks yet, the
   CPUs held in the lockstep).
2. The parks, and a save and load at vblank in M2 with the gate above.
3. The engine and DDR in the top, the UI (OSD and keys), the board.
4. The SDRAM-work-RAM bitstreams.
