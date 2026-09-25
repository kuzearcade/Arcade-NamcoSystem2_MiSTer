# M1: ns2_video against MAME's pictures (tb.cpp)
#   make && ./obj_dir/Vns2_video SET ../../oracle/traces/SET_attract [first [last [every]]]
R := ../../../rtl
SRCS := $(R)/ns2_video.sv $(R)/ns2_c123.sv $(R)/ns2_roz.sv $(R)/ns2_c45.sv $(R)/ns2_c169.sv $(R)/ns2_c355.sv $(R)/ns2_sprite_a.sv
obj_dir/Vns2_video: tb.cpp $(SRCS) Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH --top-module ns2_video $(SRCS) tb.cpp -o Vns2_video
