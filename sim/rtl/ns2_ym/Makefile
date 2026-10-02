# NS2-26: the YM2151 path (ns2_ym_fifo + jt51) against MAME's writes (tb.cpp)
#   make && ./obj_dir/Vtop LOG OUT.raw SECONDS
R := ../../../rtl
J := $(R)/third_party/jt51/hdl
obj_dir/Vtop: tb.cpp top.sv $(R)/ns2_ym_fifo.sv Makefile
	verilator --cc --exe --build -O3 -Wno-fatal -I$(J) --top-module top top.sv $(R)/ns2_ym_fifo.sv $(J)/*.v tb.cpp -o Vtop
