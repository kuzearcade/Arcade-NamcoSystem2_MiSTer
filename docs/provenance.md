# Provenance

Where every file came from. Third-party files keep their own licence notices.

## Vendored and copied

| file | from | status |
|---|---|---|
| `sys/` | Template_MiSTer (via Arcade-GingaNin_MiSTer) | verbatim |
| `rtl/third_party/fx68k`, `hiscore`, `crt_adjust` | Arcade-GingaNin_MiSTer (its pins) | verbatim |
| `rtl/third_party/mc6809/mc6809is.v` | Arcade-GingaNin_MiSTer | as there: GN-4's power-up latch values |
| `rtl/third_party/jt51/` | Arcade-JalecoMS1BCD_MiSTer (jotego/jt51 @ 985a573) | verbatim, GPL-3.0-or-later |
| `rtl/savestate/*` | Arcade-GingaNin_MiSTer | as there (ss_m68k_park with GN-10's `stall`, ss_m6809_park new there) |
| `rtl/sdram.sv`, `sdram_arb.sv`, `sdram_req.sv`, `crt_chain.sv`, `cheats.sv`, `video_retime.sv` | Arcade-GingaNin_MiSTer | verbatim |
| `sim/models/sdram_model.sv` | Arcade-GingaNin_MiSTer (from Arcade-NMKBP964_MiSTer) | verbatim |
| `rtl/third_party/jt680x/jt6805*.v`, `jt65c02*.v`, `6805.yaml`, `65c02.yaml` | jotego/jtcores `modules/jt680x` @ 3eb8fec | GPL-3.0-or-later, verbatim: the C65 (HD63705) and C68 (M37450) bases, extended in M2 |
| `rtl/third_party/jt680x/6805.{uc,vh}`, `6805_param.vh`, `65c02.*` | generated from the YAML by jtframe's `ucode` at the same pin (`tools/gen_ucode.sh`) | generated |
| `rtl/third_party/jtframe_sdram64/*.v` | jotego/jtcores `modules/jtframe/hdl/sdram/` @ 3eb8fec | GPL-3.0-or-later. Verbatim except one line of `jtframe_sdram64_bank.v`: PRE_RD advances on `do_read`, not `bg && !all_dqm`. The original could skip a READ while another bank held the data bus (NS2-3) |

## New

| file | notes |
|---|---|
| `tools/ns2_romdata.py` | the ROM table, parsed from MAME's driver; the board-wiring transforms (NS2-1) |
| `tools/ns2_regions.py`, `sim/oracle/ns2_regions.lua` | the region proof against MAME (NS2-1) |
| `tools/mame-patches/ns2-oracle.patch` | MAME 0.289: the key custom's `rand()` reads replaced by a seeded LFSR (D5); `NS2_MUTE_YM` / `NS2_MUTE_C140` |
| `sim/oracle/ns2_capture.lua`, `ns2_boot.lua`, `tools/ns2_capture.py` | the oracle capture: state, pictures, per-line register writes of both 68000s (NS2-2) |
| `tools/ns2_model.py` | the reference renderer, exact against MAME (NS2-2) |
| `tools/ns2_load.py` | Q3: the graphics fetch load per line, the caches, the replay streams (NS2-3) |
| `sim/models/sdram_model_burst.sv` | a burst SDRAM model with a mode register and timing checks (NS2-3) |
| `sim/rtl/sdram_probe/` | the D3 bandwidth probe (NS2-3) |
| `sim/oracle/ns2_ramuse.lua` | Q2: work RAM pages touched per 68000 (NS2-4) |
| `sim/quartus/m10k_probe/` | Appendix F's M10K probe (NS2-4) |
| `rtl/ns2_video.sv`, `ns2_c123.sv`, `ns2_roz.sv`, `ns2_c45.sv`, `ns2_c169.sv`, `ns2_c355.sv`, `ns2_sprite_a.sv` | the video (M1), from the model line for line (NS2-2, NS2-5) |
| `sim/rtl/video_state/` | M1's testbench: state injection, MAME's bands, stall injection, the comparison with MAME's pictures |
| `tools/ns2_c355hw.py` | the C355 as the RTL computes it, proven equal to MAME's algorithm (NS2-5) |
| `rtl/ns2_hd63705*.v` | derived from jt6805 (GPL-3.0-or-later): the C65's HD63705Z0 as MAME implements it (16-bit addresses, page-1 stack, 4-bit vectors, IRQ1 and the A/D interrupt) |
| `sim/rtl/mcu/`, `sim/oracle/ns2_mcutrace.lua` | the MCU harness against MAME's own MCU traces |
| `tools/gen_ucode.sh` | rebuilds jt680x's microcode with jtframe's generator |
| `tools/ns2_romdump.py` | the graphics ROMs for the testbenches (git-ignored output) |
| `sim/oracle/ns2_play.lua` | scripted play for any set (coin, start, a fixed input pattern) |
