# ns2_sdram (M3) against the burst SDRAM model (tb.cpp)
R := ../../../rtl
obj_dir/Vtop: tb.cpp top.sv $(R)/ns2_sdram.sv $(wildcard $(R)/third_party/jtframe_sdram64/*.v) ../../models/sdram_model_burst.sv Makefile
	verilator --cc --exe --build -O3 -j 4 -CFLAGS -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN \
		-I$(R)/third_party/jtframe_sdram64 --top-module top top.sv $(R)/ns2_sdram.sv \
		$(wildcard $(R)/third_party/jtframe_sdram64/*.v) ../../models/sdram_model_burst.sv tb.cpp -o Vtop
