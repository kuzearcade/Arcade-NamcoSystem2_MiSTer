# The C140 alone against MAME's samples (tb.cpp)
#   make && ./obj_dir/Vns2_c140 SET TRACE_DIR [samples]
R := ../../../rtl
obj_dir/Vns2_c140: tb.cpp $(R)/ns2_c140.sv Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-GMAME_RATE=1 --top-module ns2_c140 $(R)/ns2_c140.sv tb.cpp -o Vns2_c140
