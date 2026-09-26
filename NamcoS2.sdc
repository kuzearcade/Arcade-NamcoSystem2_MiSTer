# Namco System 2 timing constraints (docs/known-issues.md NS2-13).
#
# sys/sys_top.sdc is the MiSTer framework's own base file (root clocks,
# virtual clocks, exclusive groups, OSD/scaler false paths).
source sys/sys_top.sdc

derive_pll_clocks
derive_clock_uncertainty

# ------------------------------------------------------------------
# Core clocks: rtl/pll_ns2.v's three outputs (clk_sys 49.152 MHz, clk_sd
# 98.304 MHz, the SDRAM chip's clock). They are ONE group, related:
# ns2_sdram's request FIFOs and data registers cross between clk_sys and
# clk_sd as register-to-register paths of one fast period (the two clocks
# are in phase, from one PLL), so those paths are timed.
# ------------------------------------------------------------------
set core_clocks [get_clocks {emu|pll|altera_pll_i|*|divclk}]
set_clock_groups -exclusive \
	-group $core_clocks \
	-group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {spi_sck}] \
	-group [get_clocks {hdmi_sck}] \
	-group [get_clocks {*|h2f_user0_clk}] \
	-group [get_clocks {FPGA_CLK1_50}] \
	-group [get_clocks {FPGA_CLK2_50}] \
	-group [get_clocks {FPGA_CLK3_50}]

# video_retime moves the raster from clk_sys to CLK_VIDEO (clk_sd) through a
# two-line buffer read a line behind, and places its read side once per
# frame: its crossings are not single-cycle paths.
set_false_path -from [get_registers {*|video_retime:video_retime|*}] -to [get_registers {*|video_retime:video_retime|*}]
set_false_path -from [get_registers {*|ns2_board:board|*}] -to [get_registers {*|video_retime:video_retime|*}]

# The slow CPUs change their registers only on their clock enables, at
# least 6 clocks apart (the 6809: fallE and fallQ, 18 and 6 apart; the C65's
# HD63705 and the C68's M37450: once in 24). Everything that takes their
# outputs does so on an enable of theirs, or (the ROM caches) 5 clocks after
# (ns2_rom_cache SAMPLED): 4 clocks for their paths.
foreach cpu {*u_sound|mc6809is:u_cpu|* *u_mcu|ns2_hd63705:u_cpu|* *u_c68|ns2_m740:u_cpu|*} {
	set_multicycle_path -setup -end 4 -from [get_registers $cpu] -to [get_registers *]
	set_multicycle_path -hold -end 3 -from [get_registers $cpu] -to [get_registers *]
}

# ------------------------------------------------------------------
# CRT Adjust multicycle (crt_vsize: written on the second clock of an output
# line, consumed on the fourth).
# ------------------------------------------------------------------
set vsz_ac [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_active_cyc[*]}]
set vsz_ds [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_de_start[*]}]
set_multicycle_path -setup 2 -from $vsz_ac -to $vsz_ds
set_multicycle_path -hold  1 -from $vsz_ac -to $vsz_ds

# The DIP bank and the set's configuration change only while the core is
# held in reset for the download and its tail (MS1-53), so nothing samples
# them on the clock they change.
set_false_path -from [get_registers {*|dip_sw[*][*]}]
set_false_path -from [get_registers {emu|cfg[*][*]}]
