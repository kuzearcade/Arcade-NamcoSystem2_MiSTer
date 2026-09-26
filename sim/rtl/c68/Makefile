# The C68 alone against MAME's trace of it (tb.cpp)
#   make && ./obj_dir/Vns2_c68 SET TRACE_DIR [cycles]
R := ../../../rtl
obj_dir/Vns2_c68: tb.cpp $(R)/ns2_c68.sv $(R)/ns2_m740.sv Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-Wno-BLKSEQ -Wno-CASEINCOMPLETE --public-flat-rw --top-module ns2_c68 $(R)/ns2_c68.sv $(R)/ns2_m740.sv tb.cpp -o Vns2_c68
