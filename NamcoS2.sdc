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

# The set's configuration changes only while the core is held in reset for
# the download and its tail (MS1-53), so nothing samples it on the clock it
# changes. (The DIP bank now changes while the game runs, NS2-22: timed.)
set_false_path -from [get_registers {emu|cfg[*][*]}]

# ------------------------------------------------------------------
# The SDRAM interface (NS2-19). Without these the pins are unconstrained and
# nothing checks the chip clock's phase (rtl/pll_ns2.v outclk_2, forwarded
# through an altddio_out). The chip, CL2 at 98.304 MHz, as the MiSTer SDRAM
# boards' slowest parts allow: tAC 6.0 ns, tOH 2.5 ns, tIS 1.5 ns, tIH
# 0.8 ns; the board's traces 0.3-1.0 ns each way.
# - Commands, addresses, masks and write data leave on a clk_sd edge from
#   the I/O registers, for the chip's next edge.
# - Read data: jtframe_sdram64 (CL2, SHIFTED=0) takes the word the chip
#   drives from its edge on the second clk_sd edge after it (multicycle 2).
# ------------------------------------------------------------------
create_generated_clock -name sdram_clk_pin -source [get_pins {emu|pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]
set sd_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_DQ[*]}]
set_output_delay -clock sdram_clk_pin -max [expr 1.5 + 1.0 - 0.3] $sd_out
set_output_delay -clock sdram_clk_pin -min [expr -0.8 + 0.3 - 1.0] $sd_out
set_input_delay  -clock sdram_clk_pin -max [expr 6.0 + 1.0 + 1.0] [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk_pin -min [expr 2.5 + 0.3 + 0.3] [get_ports {SDRAM_DQ[*]}]
set_multicycle_path -setup -end 2 -from [get_clocks sdram_clk_pin] -to [get_clocks {emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold  -end 1 -from [get_clocks sdram_clk_pin] -to [get_clocks {emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# ------------------------------------------------------------------
# ns2_sdram's request FIFOs and its bursts back (NS2-20): clk writes an entry and its Gray write
# pointer; clk_sd takes the pointer through a register, so it reads an entry
# at least one clk_sd edge after the write, never on the edge of it. clk_sd's
# network reaches its registers about 1 ns after clk's, and on that shared
# edge an entry's short path to jtframe's latch cannot be padded (both in one
# LAB): the hold check moves to the edge before. The read pointer goes back
# the same way (Gray; clk sees it late, so the FIFO is never seen too full).
# ------------------------------------------------------------------
set sd_clk_sys {emu|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set sd_clk_sd  {emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set_multicycle_path -hold -end 1 -from [get_registers {*|ns2_sdram:sdram|g_req[*].q[*]* *|ns2_sdram:sdram|g_req[*].g_w.q_* *|ns2_sdram:sdram|g_req[*].wp_g[*]}] -to [get_clocks $sd_clk_sd]
set_multicycle_path -hold -end 1 -from [get_registers {*|ns2_sdram:sdram|g_req[*].rp_g[*]}] -to [get_clocks $sd_clk_sys]
# The bursts back: ns2_sdram changes a bank's data and toggles valid_t on one
# clk_sd edge; ns2_bank_arb takes the toggle through a register of clk and the
# data a clk edge after that, never on the edge they change.
set_multicycle_path -hold -end 1 -from [get_registers {*|ns2_sdram:sdram|data0[*] *|ns2_sdram:sdram|data1[*] *|ns2_sdram:sdram|data2[*] *|ns2_sdram:sdram|data3[*] *|ns2_sdram:sdram|valid_t[*]}] -to [get_clocks $sd_clk_sys]

# hps_io's video_calc: the video's measurements (CLK_VIDEO) read into the
# HPS's register (clk_sys). The HPS polls them, and they hold for frames at a
# time, so the crossing is not timed (a hold miss appeared here on a build
# with NS2-22's flip buffer)
set_false_path -from [get_registers {*|video_calc:video_calc|vid_*}] -to [get_registers {*|video_calc:video_calc|dout[*]}]
