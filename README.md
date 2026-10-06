# Arcade-NamcoSystem2_MiSTer

A MiSTer FPGA core for **Namco System 2** (1987-1993): 61 sets, 28 games and
their alternates, on five bitstreams.

**Released.** The bitstreams and `.mra`s are in `releases/` (see
[Bitstreams](#bitstreams)) and in the [kuzecores](https://github.com/kuzearcade/kuzecores)
downloader database. Every set boots and runs its attract mode on a DE10-Nano,
and the NB-1 games (Steel Gunner 1 and 2, Suzuka 8 Hours 1 and 2, Lucky &
Wild), their Japanese alternates included, have been played on one with
simulated controls: the gun's aim, trigger and bomb, the wheel, the pedals
and Suzuka 8 Hours 2's course select. The joystick games use MAME's default
ports (one joystick, three buttons, Start, Coin, Service). The driving
games' wheel and pedals, the light guns and Metal Hawk's stick are mapped
onto the MCU's analog channels, and Assault's twin sticks onto its ports
(see [Controls](#controls)).
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

## Features

- **Pause** (OSD: Pause, and Pause when OSD is open): every CPU and both
  sound chips stop; the picture holds.
- **Direct video tweaks:** under direct video the OSD hides Aspect ratio,
  Scandoubler Fx and Orientation: the scaler paths they set do not exist
  there.
- **Autofire** (OSD): Button 1, Button 2 or both, at 15, 10, 7.5 or 30 Hz,
  both players. The options are hidden unless the `.mra` turns them on:
  the files in `releases/` do not, and `tools/ns2_autofire_mra.py` writes
  a copy of `releases/` that does into `autofire_releases/` (the same
  layout and names, `_alternatives/` included; git-ignored, so generate
  it locally). The switch is in the set's configuration block (byte 38,
  bit 0), not its DIP switches, so a saved `.dip` file does not hide it.
- **High scores** for the 35 sets in MAME's `hiscore.dat` (the plugin's
  table addresses, from `tools/ns2_extras.py`), saved with the EEPROM in the
  set's `.nvm` (OSD: High Scores & Cheats, on by default). The games that
  keep their own tables in the EEPROM need nothing more.

  High scores and cheats reach the master 68000's work RAM and the C123's
  RAM through a back door while the CPUs are held a few hundred clocks; on
  the Suzuka 8 Hours and Lucky & Wild bitstreams, whose work RAM is in the
  SDRAM, through its cache (NS2-33). Lucky & Wild has its high scores, and
  all four Suzuka and Lucky & Wild sets their Infinite Time.
- **Cheats** from Pugsy's MAME cheat database: ten fixed slots (Infinite
  Time, Infinite Credits, P1/P2 Invincibility, P1/P2 Infinite Lives, P1/P2
  Infinite Energy, Maximum Speed, P1 Infinite Weapons), each shown only for
  the sets that have it (55 sets have at least one).
- **Savestates** on every bitstream (Right Alt+F1-F4 save, F1-F4 load, or the
  OSD's Savestates page): four slots a game, kept on the SD card
  (`savestates/Arcade/<game>_<n>.ss`). The whole board is saved, every CPU
  (the 68000s and the 6809 parked at an instruction, the MCU's every
  register) and every RAM, so a load resumes exactly where the save did
  (docs/savestates.md); the YM2151's notes restart from its registers. A
  save takes about 0.1 s, a load about 0.15 s, the picture held meanwhile.

## Controls

The analog inputs follow MAME's ports and ranges (`rtl/ns2_controls.sv`);
each set's mode is in its `.mra` (config byte 33), and the button names
show in MiSTer's mapping menu.

The games on MAME's common ports have their own button names, and the
buttons a game never reads are hidden: Cosmo Gang (Fire), Dragon Saber
(Fire, Bomb), Marvel Land (Jump), Mirai Ninja (Throw, Jump), Ordyne
(Shoot, Bomb), Phelios (Fire), Rolling Thunder 2 (Shoot, Jump), Valkyrie
no Densetsu (Attack, Jump). Each was checked in MAME, a press in play
against the same run without it.

- **Wheel and pedals** (Final Lap 1-3, Four Trax, Dirt Fox, Suzuka 8
  Hours 1 and 2, Lucky & Wild): steer with the left stick, or the d-pad
  (the wheel returns to centre on release). Accelerate with Button 1 or
  the right stick up; brake with Button 2 or the right stick down (Lucky
  & Wild: Button 2 and Button 3). Button 3 shifts gear (a toggle, as the
  cabinet's lever) in Final Lap and Four Trax; Dirt Fox shifts up with
  Gear Up (Button 3) or the d-pad's down, and down with Gear Down (Button
  4) or the d-pad's up, as MAME's ports. Final Lap and Dirt Fox have no
  Start button: a credit starts the game.
- **Light guns** (Golly! Ghost!, Bubble Trouble, Steel Gunner 1 and 2,
  Lucky & Wild): a MiSTer light gun, the left stick or the d-pad aims
  (player 2: the second pad's), whichever moved last; the d-pad moves the
  sight and leaves it there. In Lucky & Wild player 1's d-pad steers, so
  player 1 aims with a gun, the stick or the mouse, and player 2 with
  anything. The mouse aims for player 1, with its left button the
  trigger and its right button Steel Gunner's missile. Button 1 is the
  trigger, and Button 2 the missile. The aim matches the game's own sight,
  flipped for the ROT180 sets. The OSD's "Gun crosshair" (shown only for
  these sets) draws a white cross for player 1 and a yellow one for player
  2, once player 2 has aimed.
- **Assault** (and Assault Plus): two 4-way sticks a player, the tank's
  two tracks. The left and right analog sticks are the two sticks, each
  its own track. The right stick can also be four buttons, Right Up, Down,
  Left and Right (B6-B9): if the right stick does nothing, the pad's
  sticks are not reaching the core as analog (MiSTer sends them only when
  the pad's mapping marks them analog), so bind the right stick's four
  directions to those buttons in the core's Define joystick buttons, or
  map the pad's analog sticks in MiSTer's main menu. Until a player has
  used the right stick, the d-pad (or the left stick without analog)
  pushes both sticks the same way (forward, back, sideways); after, it is
  the left stick only. Button 1 fires; Turn Left (B3) and Turn Right (B4)
  push the sticks opposite ways; Sticks Apart (B2) and Sticks Together
  (B5) push them out and in.
- **Metal Hawk:** the left stick (or d-pad) flies, and the right stick's Y,
  or Buttons 4 and 5, move the altitude lever. Button 1 and Button 2 are
  the cabinet's two buttons.

Keyboard: arrows, Left Ctrl (B1), Left Alt (B2), Space (B3), Left Shift
(B4), Z (B5); 1 and 2 Start, 5 and 6 Coin, 9 Service. Savestates: F1-F4
load slots 1-4, Right Alt+F1-F4 save them. Left Alt+F1-F4 saves too, but
Left Alt is also Button 2, so the game sees Button 2 pressed for a moment
after the save (the brake, in the driving games); Right Alt is not mapped
to the game.

## Bitstreams

The graphics boards cannot all fit one Cyclone V together, so the core
builds five bitstreams from one source tree (`NamcoS2*.qsf`; the build is
`PROJ=<project> ./build.sh <log>`). Current release (`releases/`,
2026-10-06: tag `v2026-10-06.2`), from Quartus 17.0 Lite on the
DE10-Nano's 5CSEBA6U23I7:

| Bitstream | Boards | Sets | ALMs | Registers | M10K | DSP | Worst setup slack: clk_sys / clk_sd / HDMI / SDRAM pins | Seed |
|---|---|---|---|---|---|---|---|---|
| `NamcoS2_STD` | standard: sprites + ROZ; Final Lap / Four Trax: sprites + C45 road | 49 | 37,785 (90%) | 50,390 | 547 / 553 (99%) | 71 | +1.741 / +0.353 / +0.096 / +0.670 ns | 704 |
| `NamcoS2_MH` | Metal Hawk: sprites + C169 ROZ | 2 | 37,619 (90%) | 50,935 | 507 / 553 (92%) | 68 | +1.272 / +0.180 / +0.271 / +0.665 ns | 613 |
| `NamcoS2_SG` | Steel Gunner: C355 sprites | 4 | 37,970 (91%) | 50,740 | 497 / 553 (90%) | 73 | +1.213 / +0.093 / +0.204 / +0.655 ns | 713 |
| `NamcoS2_SZ` | Suzuka 8 Hours: C355 + C45 road; work RAMs in SDRAM | 4 | 37,602 (90%) | 51,903 | 491 / 553 (89%) | 74 | +1.697 / +0.410 / +0.119 / +0.672 ns | 620 |
| `NamcoS2_LW` | Lucky & Wild: C355 + C45 road + C169 ROZ; work RAMs in SDRAM | 2 | 41,248 (98%) | 54,148 | 551 / 553 (100%) | 78 | +1.168 / +0.278 / +0.312 / +0.654 ns | 728 |

Every clock meets timing, setup and hold, at every corner on all five,
with the SDRAM interface constrained (NS2-19). clk_sys is 49.152
MHz and clk_sd, the SDRAM's, 98.304 MHz. The 68000s run at 12.288 MHz, the
6809 and the C65 at 2.048 MHz, the C68 at 8.192 MHz. The SZ and LW
bitstreams keep both 68000 work RAMs and the C139's RAM in SDRAM behind
small caches, to fit their block RAM (NS2-15), and leave out the C65: every
set they serve has the C68 (NS2-32).

Installing: copy the `.rbf`s to `_Arcade/cores/`, the `.mra`s (and
`_alternatives/`) to `_Arcade/`, and MAME's zips (the sets, plus
`namcoc65.zip` and `namcoc68.zip`) to `games/mame/`. A missing zip is not
reported; the game loads zeros and shows a blank screen.

The core is published through
[kuzecores](https://github.com/kuzearcade/kuzecores), a custom database for
the MiSTer *downloader*, so `update_all` installs the bitstreams and the
`.mra`s (the zips are still yours to supply).

## Limitations

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
| **hiscore** ([Hiscores_MiSTer](https://github.com/MiSTer-devel/Hiscores_MiSTer)), with changes from Arcade-NMK16_MiSTer and here (`docs/provenance.md`) | Alan Steremberg, Jim Gregory | GPL-3.0-or-later | `rtl/third_party/hiscore/` |
| **savestate_ui**: the savestate keys and OSD entries, after [NES_MiSTer](https://github.com/MiSTer-devel/NES_MiSTer)'s `savestate_ui.sv` | Robert Peip | GPL-3.0 | `rtl/savestate/savestate_ui.sv` |
| **SDRAM controller** (`sdram.sv`) | Sorgelig | GPL-3.0-or-later | `rtl/sdram.sv` |
| **MiSTer framework** (Template_MiSTer `sys/`): hps_io, OSD, video mixer and scandoubler, the scaler, audio, and more | the MiSTer-devel contributors: Alexey Melnikov (Sorgelig), Till Harbaum, Ludvig Strigeus, TEMLIB (ascal), Grabulosaure, Kitrinx, bellwood420, Mike Simone; the Altera/Intel IP generated by Quartus under Intel's terms | GPL-2.0 / GPL-3.0 as marked in each file | `sys/` |

From the author's other cores (Arcade-GingaNin_MiSTer, Arcade-NMKBP964_MiSTer,
Arcade-JalecoMS1BCD_MiSTer): the savestate engine (`rtl/savestate/`),
`video_retime.sv`, `crt_chain.sv`, `cheats.sv`, `sdram_arb.sv`,
`sdram_req.sv` and `sim/models/sdram_model.sv`. `rtl/ns2_rom_cache.sv`
follows MS1BCD's `rom_cache_n`. The top level, `NamcoS2.sv`, follows
GingaNin's, itself Template_MiSTer's core template.

Data, not code, carried by the `.mra` files: the ROM sets from MAME's
`namcos2.cpp` and the DIP switches from MAME's `-listxml`; the high-score
tables from MAME's `hiscore.dat` (its hiscore plugin); the cheats from
Pugsy's MAME cheat database.

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
