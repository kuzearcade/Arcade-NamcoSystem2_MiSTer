# Arcade-NamcoSystem2_MiSTer

A MiSTer FPGA core for **Namco System 2** (1987-1993): 61 sets, 28 games and
their alternates, on five bitstreams.

**In development.** Every set boots and runs its attract mode on a DE10-Nano.
The joystick games use MAME's default ports (one joystick, three buttons,
Start, Coin, Service). The driving games' wheel and pedals, the light guns
and Metal Hawk's stick are mapped onto the MCU's analog channels, and
Assault's twin sticks onto its ports (see [Controls](#controls)).
See `docs/PLAN.md` for the plan and its gates, and `docs/known-issues.md`
for every finding (NS2-n).

GPL-3.0 (see `LICENSE`); third-party files keep their own notices.

## Goals

- **MAME as the reference.** MAME's `namco/namcos2.cpp` (K. Wilkins) and
  its devices, at a pinned commit (`deps.lock`), define the behaviour. Every
  claim about the board is a measurement against it, recorded as a
  numbered finding in `docs/known-issues.md`.
- **Gates are measurements.** Each milestone ends in a measured gate, not
  a judgement: the video against MAME's state (M1), the whole board
  against MAME's bus traces (M2), the board with its ROMs in the SDRAM
  (M3), timing met and the sets running on the board (M4), feature parity
  (M5), the release (M6).
- **Cycle-faithful CPUs.** Both 68000s, the 6809 and the I/O MCU (C65 or
  C68) run at MAME's clocks and bus timing. A cache miss stops every CPU
  together, so the caches never change their timing against each other.
- **Every set in MAME's driver**, including Final Lap 1-3, Four Trax and the
  NB-1 boards (Steel Gunner, Suzuka 8 Hours, Lucky & Wild).
- **No ROM data in the repository.** The `.mra`s assemble the sets from
  MAME's zips; nothing derived from a ROM is committed.
- **Feature parity with the author's other cores** (Arcade-GingaNin,
  NMK16, SandScrp, JalecoMS1BCD/MS1Z, NMKBP964): savestates, NVRAM high
  scores, cheats, autofire, pause, light guns and analog controls, CRT
  Adjust.

## Supported games

The `.mra`s are in `releases/`, the alternates in
`releases/_alternatives/_<game>/`. Each loads its bitstream by name.

| Game | Year | MAME set | Bitstream | Controls | Alternates |
|---|---|---|---|---|---|
| Final Lap (Rev E) | 1987 | `finallap` | STD | wheel, pedals, gear | `finallapc`, `finallapd`, `finallapjb`, `finallapjc` |
| Assault (Rev B) | 1988 | `assault` | STD | two joysticks per player | `assaultj`, `assaultp` |
| Metal Hawk (Rev C) | 1988 | `metlhawk` | MH | analog stick, lever | `metlhawkj` |
| Mirai Ninja (Japan, set 1) | 1988 | `mirninja` | STD | joystick | `mirninjaa` |
| Ordyne (World) | 1988 | `ordyne` | STD | joystick | `ordynej`, `ordyneje` |
| Phelios | 1988 | `phelios` | STD | joystick | `pheliosj` |
| Burning Force (Japan, new version (Rev C)) | 1989 | `burnforc` | STD | joystick | `burnforco` |
| Dirt Fox (Japan) | 1989 | `dirtfoxj` | STD | wheel, pedals, gears | |
| Finest Hour (Japan) | 1989 | `finehour` | STD | joystick | |
| Four Trax (World) | 1989 | `fourtrax` | STD | wheel, pedals, gear | `fourtraxa`, `fourtraxj` |
| Marvel Land (Japan) | 1989 | `marvland` | STD | joystick | `marvlandup` |
| Valkyrie no Densetsu (Japan) | 1989 | `valkyrie` | STD | joystick | English translation by A-M (patches `valkyrie`) |
| Dragon Saber (World, DO2) | 1990 | `dsaber` | STD | joystick | `dsabera`, `dsaberj` |
| Final Lap 2 (World, Rev B) | 1990 | `finalap2` | STD | wheel, pedals, gear | `finalap2j`, `finalap2jb` |
| Golly! Ghost! | 1990 | `gollygho` | STD | light guns | |
| Kyuukai Douchuuki (Japan, new version (Rev B)) | 1990 | `kyukaidk` | STD | joystick | `kyukaidko` |
| Rolling Thunder 2 | 1990 | `rthun2` | STD | joystick | `rthun2j` |
| Steel Gunner (Rev B) | 1990 | `sgunner` | SG | light guns | `sgunnerj` |
| Cosmo Gang the Video (US) | 1991 | `cosmogng` | STD | joystick | `cosmogngj` |
| Steel Gunner 2 (US) | 1991 | `sgunner2` | SG | light guns | `sgunner2j` |
| Bubble Trouble - Golly! Ghost! 2 (World, Rev B) | 1992 | `bubbletr` | STD | light guns | `bubbletrj` |
| Final Lap 3 (World, Rev C) | 1992 | `finalap3` | STD | wheel, pedals, gear | `finalap3a`, `finalap3bl`, `finalap3j`, `finalap3jc` |
| Lucky & Wild | 1992 | `luckywld` | LW | wheel, pedals, light guns | `luckywldj` |
| Super World Stadium (Japan) | 1992 | `sws` | STD | joystick | |
| Super World Stadium '92 (Japan) | 1992 | `sws92` | STD | joystick | `sws92g` |
| Suzuka 8 Hours (World, Rev C) | 1992 | `suzuka8h` | SZ | wheel, pedals | `suzuka8hj` |
| Suzuka 8 Hours 2 (World, Rev B) | 1993 | `suzuk8h2` | SZ | wheel, pedals | `suzuk8h2j` |
| Super World Stadium '93 (Japan) | 1993 | `sws93` | STD | joystick | |

Tested on the board: every standard-bitstream set (22 parents and 27
alternates), and the parents on the other four bitstreams.

## Controls

The analog inputs follow MAME's ports and ranges (`rtl/ns2_controls.sv`);
each set's mode is in its `.mra` (config byte 33), and the button names
show in MiSTer's mapping menu.

- **Wheel and pedals** (Final Lap 1-3, Four Trax, Dirt Fox, Suzuka 8
  Hours 1 and 2, Lucky & Wild): steer with the left stick, or the d-pad
  (the wheel returns to centre on release). Accelerate with Button 1 or
  the right stick up; brake with Button 2 or the right stick down (Lucky
  & Wild: Button 2 and Button 3). Button 3 shifts gear (a toggle, as the
  cabinet's lever) in Final Lap and Four Trax; Dirt Fox shifts up with
  down and down with up. Final Lap and Dirt Fox have no Start button: a
  credit starts the game.
- **Light guns** (Golly! Ghost!, Bubble Trouble, Steel Gunner 1 and 2,
  Lucky & Wild): a MiSTer light gun, the left stick or the d-pad aims
  (player 2: the second pad's), whichever moved last; the d-pad moves the
  sight and leaves it there. In Lucky & Wild player 1's d-pad steers, so
  player 1 aims with a gun, the stick or the mouse, and player 2 with
  anything. The mouse aims for player 1, with its left button the
  trigger and its right button Steel Gunner's missile. Button 1 is the
  trigger, and Button 2 the missile. The aim matches the game's own sight,
  flipped for the ROT180 sets. The OSD's "Gun crosshair" shows a white
  cross for player 1 and a yellow one for player 2, once player 2 has aimed.
- **Assault** (and Assault Plus): two 4-way sticks a player, the tank's
  two tracks. The left and right analog sticks are the two sticks, each
  its own track; with neither pushed, the d-pad pushes both the same way
  (forward, back, sideways). Button 1
  fires; Turn Left (B3) and Turn Right (B4) push the sticks opposite ways;
  Sticks Apart (B2) and Sticks Together (B5) push them out and in.
- **Metal Hawk:** the left stick (or d-pad) flies, and the right stick's Y,
  or Buttons 4 and 5, move the altitude lever. Button 1 and Button 2 are
  the cabinet's two buttons.

Keyboard: arrows, Left Ctrl (B1), Left Alt (B2), Space (B3), Left Shift
(B4), Z (B5); 1 and 2 Start, 5 and 6 Coin.

## Bitstreams

The graphics boards cannot all fit one Cyclone V together, so the core
builds five bitstreams from one source tree (`NamcoS2*.qsf`; the build is
`PROJ=<project> ./build.sh <log>`). Current release (`releases/`,
2026-10-01, second build: tag `v2026-10-01.2`), from Quartus 17.0 Lite on the
DE10-Nano's 5CSEBA6U23I7:

| Bitstream | Boards | Sets | ALMs | Registers | M10K | DSP | Worst setup slack: clk_sys / clk_sd / HDMI / SDRAM pins | Seed |
|---|---|---|---|---|---|---|---|---|
| `NamcoS2_STD` | standard: sprites + ROZ; Final Lap / Four Trax: sprites + C45 road | 49 | 36,876 (88%) | 56,325 | 537 / 553 (97%) | 69 | +1.745 / +0.146 / +0.230 / +0.644 ns | 7 |
| `NamcoS2_MH` | Metal Hawk: sprites + C169 ROZ | 2 | 37,261 (89%) | 57,050 | 497 / 553 (90%) | 66 | +1.226 / +0.256 / +0.172 / +0.632 ns | 11 |
| `NamcoS2_SG` | Steel Gunner: C355 sprites | 4 | 37,207 (89%) | 56,892 | 487 / 553 (88%) | 71 | +0.863 / +0.466 / +0.191 / +0.686 ns | 15 |
| `NamcoS2_SZ` | Suzuka 8 Hours: C355 + C45 road; work RAMs in SDRAM | 4 | 38,074 (91%) | 57,960 | 486 / 553 (88%) | 72 | +1.654 / +0.062 / +0.082 / +0.632 ns | 17 |
| `NamcoS2_LW` | Lucky & Wild: C355 + C45 road + C169 ROZ; work RAMs in SDRAM | 2 | 41,489 (99%) | 60,245 | 546 / 553 (99%) | 76 | +0.936 / +0.125 / +0.047 / +0.670 ns | 37 |

Every clock meets timing, setup and hold, at every corner on all five,
with the SDRAM interface constrained (NS2-19). clk_sys is 49.152
MHz and clk_sd, the SDRAM's, 98.304 MHz. The 68000s run at 12.288 MHz, the
6809 and the C65 at 2.048 MHz, the C68 at 8.192 MHz. The SZ and LW
bitstreams keep both 68000 work RAMs and the C139's RAM in SDRAM behind
small caches, to fit their block RAM (NS2-15).

Installing: copy the `.rbf`s to `_Arcade/cores/`, the `.mra`s (and
`_alternatives/`) to `_Arcade/`, and MAME's zips (the sets, plus
`namcoc65.zip` and `namcoc68.zip`) to `games/mame/`. A missing zip is not
reported; the game loads zeros and shows a blank screen.

The core is published through
[kuzecores](https://github.com/kuzearcade/kuzecores), a custom database for
the MiSTer *downloader*, so `update_all` installs the bitstreams and the
`.mra`s (the zips are still yours to supply).

## To Do

- **Feature parity (M5):** savestates, pause, cheats, autofire.
- **Pictures against MAME:** the remaining line differences in Suzuka 8
  Hours and Lucky & Wild (the replay matches 667 and 643 of 699 frames),
  and Final Lap's ranking row 6.
- **Audio:** jt51's timbre on some FM instruments against MAME's YM2151,
  and its 55.9 kHz output's aliasing at 48 kHz (NS2-26: the levels and the
  C140 match MAME); the C68 in M2 (NS2-8).
- **The board:** load the Steel Gunner, Suzuka and Lucky & Wild alternates
  on hardware; test play with real controls.
- **Other boards:** confirm NS2-19's fix (refresh through the download, the
  SDRAM clock at 171 degrees) on the boards that reported black screens and
  crashes; the test board never showed them.

The C139 serial link between cabinets is not emulated (nor is it in MAME):
each cabinet plays alone.

## Credits and third-party code

The core includes code by other authors, each under its own licence, kept
with the files. `deps.lock` pins every source, and `docs/provenance.md` says
which file came from where and what was changed.

| Code | Author(s) | Licence | Where |
|---|---|---|---|
| **fx68k**: the two 68000s | Jorge Cwik | GPL-3.0 | `rtl/third_party/fx68k/` |
| **mc6809is**: the sound CPU (6809) | Greg Miller; the synchronous version by Sorgelig | BSD (the standard licence of its dual licence; below) | `rtl/third_party/mc6809/` |
| **JT51**: the YM2151 | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `rtl/third_party/jt51/` |
| **jt680x** (jt6805, jt65c02) and its microcode: the base of the C65 (HD63705) MCU in `rtl/ns2_hd63705*.v` and `rtl/63705.*` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `rtl/third_party/jt680x/` |
| **jtframe_sdram64**: the SDRAM controller, with local fixes (`docs/provenance.md`) | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `rtl/third_party/jtframe_sdram64/` |
| **CRT Adjust** (crt_adjust, crt_vsize): the analog geometry controls | Umberto Parisi (rmonic79), with help from Andrea Bogazzi (asturur) | GPL-3.0-or-later | `rtl/third_party/crt_adjust/` |
| **hiscore** | Alan Steremberg, Jim Gregory | GPL-3.0-or-later | `rtl/third_party/hiscore/` |
| **SDRAM controller** (`sdram.sv`) | Sorgelig | GPL-3.0-or-later | `rtl/sdram.sv` |
| **MiSTer framework** (Template_MiSTer `sys/`): hps_io, OSD, video mixer and scandoubler, the scaler, audio, and more | the MiSTer-devel contributors: Alexey Melnikov (Sorgelig), Till Harbaum, Ludvig Strigeus, TEMLIB (ascal), Grabulosaure, Kitrinx, bellwood420, Mike Simone; the Altera/Intel IP generated by Quartus under Intel's terms | GPL-2.0 / GPL-3.0 as marked in each file | `sys/` |

From the author's other cores (Arcade-GingaNin_MiSTer, Arcade-NMKBP964_MiSTer,
Arcade-JalecoMS1BCD_MiSTer): the savestate engine (`rtl/savestate/`),
`video_retime.sv`, `crt_chain.sv`, `cheats.sv`, `sdram_arb.sv`,
`sdram_req.sv` and `sim/models/sdram_model.sv`. `rtl/ns2_rom_cache.sv`
follows MS1BCD's `rom_cache_n`.

Derived from MAME (BSD-3-Clause), besides its use as the behavioural
reference:
- `rtl/ns2_m740.sv` (the C68's 740 core) is generated by
  `tools/ns2_740gen.py` from MAME's `dm740.lst`, `om740.lst` and
  `om6502.lst`, by Olivier Galibert; its helpers are transcribed from
  `m6502.cpp` and `m740.cpp`.
- `rtl/ns2_c140.sv` ports MAME's `sound/c140.cpp`, by R. Belmont.
- `tools/ns2_romdata.py` reads its ROM tables from MAME's `namcos2.cpp`
  (K. Wilkins and the MAME contributors).

mc6809is is used under the standard BSD licence of its dual licence, whose
notice is reproduced here as it requires:

    Copyright (c) 2016, Greg Miller
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above copyright
          notice, this list of conditions and the following disclaimer in the
          documentation and/or other materials provided with the distribution.
        * The name of the author may not be used to endorse or promote products
          derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL GREG MILLER BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
