# M2: the C65's HD63705 against MAME's MCU traces (tb.cpp)
#   make && ./obj_dir/Vns2_hd63705 SET TRACE_DIR [max_accesses]
R := ../../../rtl
J := $(R)/third_party/jt680x
SRCS := $(R)/ns2_hd63705.v $(R)/ns2_hd63705_ctrl.v $(R)/ns2_hd63705_alu.v $(R)/ns2_hd63705_regs.v
obj_dir/Vns2_hd63705: tb.cpp $(SRCS) Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 -Wno-fatal -Wno-WIDTH -I$(R) --public-flat-rw \
		--top-module ns2_hd63705 $(SRCS) tb.cpp -o Vns2_hd63705
	ln -sf $(R)/63705.uc 63705.uc
