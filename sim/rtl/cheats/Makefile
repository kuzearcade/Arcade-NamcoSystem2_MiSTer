# NS2-30: rtl/cheats.sv against the table it is given (tb.cpp)
#   make && ./obj_dir/Vcheats SET    (the set's <rom index="5"> from releases/)
obj_dir/Vcheats: tb.cpp ../../../rtl/cheats.sv Makefile
	verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -GSLOTS=10 -GACTS=3 --top-module cheats ../../../rtl/cheats.sv tb.cpp -o Vcheats
