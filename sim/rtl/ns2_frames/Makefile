# M2: the whole board from power-on against MAME's bus traces (tb.cpp; CPU=slave for the slave)
#   make && KEY="$(tools/ns2_keys.py --tb SET)" ./obj_dir/Vns2_board SET TRACE [max]
R := ../../../rtl
T := $(R)/third_party
SRCS := $(R)/ns2_board.sv $(R)/ns2_main.sv $(R)/ns2_cpu.sv $(R)/ns2_c148.sv $(R)/ns2_key.sv \
	$(R)/ns2_video.sv $(R)/ns2_c123.sv $(R)/ns2_roz.sv $(R)/ns2_c45.sv $(R)/ns2_c169.sv $(R)/ns2_c355.sv $(R)/ns2_sprite_a.sv \
	$(R)/ns2_c65.sv $(R)/ns2_c68.sv $(R)/ns2_m740.sv $(R)/ns2_hd63705.v $(R)/ns2_hd63705_ctrl.v $(R)/ns2_hd63705_alu.v $(R)/ns2_hd63705_regs.v \
	$(R)/ns2_sound.sv $(R)/ns2_c140.sv \
	$(T)/fx68k/fx68k.sv $(T)/fx68k/fx68kAlu.sv $(T)/fx68k/uaddrPla.sv $(T)/mc6809/mc6809is.v $(wildcard $(T)/jt51/hdl/*.v)
obj_dir/Vns2_board: tb.cpp $(SRCS) Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -I$(R) -I$(T)/fx68k \
		-GC140_MAME_RATE=1 --top-module ns2_board $(SRCS) tb.cpp -o Vns2_board
	ln -sf $(R)/63705.uc 63705.uc
	ln -sf $(T)/fx68k/microrom.mem microrom.mem
	ln -sf $(T)/fx68k/nanorom.mem nanorom.mem
