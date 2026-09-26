# M3: the board with its ROMs in the SDRAM, from the download (tb.cpp)
#   make && KEY="$(tools/ns2_keys.py --tb SET)" ./obj_dir/Vtop SET TRACE [last_frame]
R := ../../../rtl
T := $(R)/third_party
SRCS := top.sv $(R)/ns2_board.sv $(R)/ns2_main.sv $(R)/ns2_cpu.sv $(R)/ns2_c148.sv $(R)/ns2_key.sv \
	$(R)/ns2_video.sv $(R)/ns2_c123.sv $(R)/ns2_roz.sv $(R)/ns2_c45.sv $(R)/ns2_c169.sv $(R)/ns2_c355.sv $(R)/ns2_sprite_a.sv \
	$(R)/ns2_c65.sv $(R)/ns2_c68.sv $(R)/ns2_m740.sv $(R)/ns2_hd63705.v $(R)/ns2_hd63705_ctrl.v $(R)/ns2_hd63705_alu.v $(R)/ns2_hd63705_regs.v \
	$(R)/ns2_sound.sv $(R)/ns2_c140.sv $(R)/ns2_rom_cache.sv $(R)/ns2_mem.sv $(R)/ns2_bank_arb.sv $(R)/ns2_sdram.sv \
	$(wildcard $(T)/jtframe_sdram64/*.v) ../../models/sdram_model_burst.sv \
	$(T)/fx68k/fx68k.sv $(T)/fx68k/fx68kAlu.sv $(T)/fx68k/uaddrPla.sv $(T)/mc6809/mc6809is.v $(wildcard $(T)/jt51/hdl/*.v)
obj_dir/Vtop: tb.cpp $(SRCS) Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-BLKSEQ -I$(R) -I$(T)/fx68k \
		--top-module top $(SRCS) tb.cpp -o Vtop
	ln -sf $(R)/63705.uc 63705.uc
	ln -sf $(T)/fx68k/microrom.mem microrom.mem
	ln -sf $(T)/fx68k/nanorom.mem nanorom.mem
