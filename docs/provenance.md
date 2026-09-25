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

## New

| file | notes |
|---|---|
| `tools/ns2_romdata.py` | the ROM table, parsed from MAME's driver; the board-wiring transforms (NS2-1) |
| `tools/ns2_regions.py`, `sim/oracle/ns2_regions.lua` | the region proof against MAME (NS2-1) |
