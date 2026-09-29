# NS2-22: the flip buffer against a DDR model (tb.cpp)
#   make && ./obj_dir/Vns2_flipbuf; SLOW=1 ./obj_dir/Vns2_flipbuf
R := ../../../rtl
obj_dir/Vns2_flipbuf: tb.cpp $(R)/ns2_flipbuf.sv Makefile
	verilator --cc --exe --build -O2 -Wno-fatal --top-module ns2_flipbuf $(R)/ns2_flipbuf.sv tb.cpp -o Vns2_flipbuf
