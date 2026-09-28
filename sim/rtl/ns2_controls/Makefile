# ns2_controls alone: every control mode against the values MAME's input
# ports give (namcos2.cpp), from scripted sticks, buttons and mouse packets
#   make && ./obj_dir/Vns2_controls
R := ../../../rtl
obj_dir/Vns2_controls: tb.cpp $(R)/ns2_controls.sv Makefile
	verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module ns2_controls $(R)/ns2_controls.sv tb.cpp -o Vns2_controls
