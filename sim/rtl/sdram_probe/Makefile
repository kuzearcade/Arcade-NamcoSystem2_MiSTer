# D3's SDRAM bandwidth probe: make && ./obj_dir/Vprobe_top EN P0 P1 P2 P3 PATTERN [MS]
# The gate (docs/PLAN.md 2.3): with the streams of tools/ns2_load.py --dump,
#   REPLAY=b0,b1,b2,b3 ./obj_dir/Vprobe_top 0xF 27 27 22 32 0 20
# every bank's backlog bounded at 1.5x the worst measured line load.
J := ../../../rtl/third_party/jtframe_sdram64
# jtframe_sdram64's bank arbitration: 0 = randomised (the D3 choice), 1 = fixed
# priority to bank 0 (starves banks 2 and 3 under load)
BAPRIO ?= 0
SRCS := probe_top.sv ../../models/sdram_model_burst.sv $(wildcard $(J)/*.v)
obj_dir/Vprobe_top: tb.cpp $(SRCS) Makefile
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
		-Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-LATCH \
		-DVERILATOR -GBAPRIO=$(BAPRIO) --top-module probe_top $(SRCS) tb.cpp -o Vprobe_top
