create_clock -name clk -period 20.345 [get_ports clk]
create_clock -name clk_sd -period 10.172 [get_ports clk_sd]
set_clock_groups -asynchronous -group {clk} -group {clk_sd}

# The slow CPUs change their registers only on their clock enables, at
# least 6 clocks apart (the 6809: fallE and fallQ, 18 and 6 apart; the C65's
# HD63705 and the C68's M37450: once in 24). Everything that takes their
# outputs does so on an enable of theirs, or (the ROM caches) 5 clocks after
# (ns2_rom_cache SAMPLED): 4 clocks for their paths.
foreach cpu {*u_sound|mc6809is:u_cpu|* *u_mcu|ns2_hd63705:u_cpu|* *u_c68|ns2_m740:u_cpu|*} {
	set_multicycle_path -setup -end 4 -from [get_registers $cpu] -to [get_registers *]
	set_multicycle_path -hold -end 3 -from [get_registers $cpu] -to [get_registers *]
}
