# NS2-29: rtl/ns2_fir4.sv against its integer model (tb.cpp), bit for bit
#   make CHIP=1 && ./obj_ym/Vns2_fir4 IN.raw SAMPLES      (the YM2151's filter)
#   make CHIP=0 && ./obj_c140/Vns2_fir4 IN.raw SAMPLES    (the C140's)
# IN.raw: s16 stereo pairs at the chip's rate (e.g. sim/rtl/ns2_ym's output)
CHIP ?= 1
SPACE := $(if $(filter 1,$(CHIP)),219,576)
OBJ := $(if $(filter 1,$(CHIP)),obj_ym,obj_c140)
R := ../../../rtl
$(OBJ)/Vns2_fir4: tb.cpp $(R)/ns2_fir4.sv $(R)/ns2_c140_fir_coef.vh $(R)/ns2_ym_fir_coef.vh Makefile
	verilator --cc --exe --build -O3 -CFLAGS -O2 -Wno-fatal -Wno-WIDTH -I$(R) -GCHIP=$(CHIP) -GSPACE=$(SPACE) \
		-CFLAGS -DCHIP=$(CHIP) -CFLAGS -DSPACE=$(SPACE) --Mdir $(OBJ) --top-module ns2_fir4 $(R)/ns2_fir4.sv tb.cpp -o Vns2_fir4
