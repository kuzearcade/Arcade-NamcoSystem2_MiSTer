# ns2_ldperf (NS2-39): the download path's speed, and the SDRAM it leaves (tb.cpp)
R := ../../../rtl
GAP ?= 8
obj_dir/Vtop: tb.cpp top.sv $(R)/ddr_rom_load.sv $(R)/ns2_mem.sv $(R)/ns2_bank_arb.sv $(R)/ns2_sdram.sv $(wildcard $(R)/third_party/jtframe_sdram64/*.v) ../../models/sdram_model_burst.sv Makefile
	verilator --cc --exe --build -O3 -j 4 -CFLAGS -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-PINMISSING \
		+define+GAP=$(GAP) -I$(R) -I$(R)/third_party/jtframe_sdram64 --top-module top top.sv $(R)/ddr_rom_load.sv $(R)/ns2_mem.sv $(R)/ns2_bank_arb.sv $(R)/ns2_sdram.sv \
		$(wildcard $(R)/third_party/jtframe_sdram64/*.v) ../../models/sdram_model_burst.sv tb.cpp -o Vtop
