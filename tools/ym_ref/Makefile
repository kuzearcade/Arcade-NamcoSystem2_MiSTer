# NS2-29: MAME's YM2151 (ymfm, from MAME's own source tree: not vendored)
# rendering a YM2151 write log, the reference for sim/rtl/ns2_ym's jt51.
#   make MAME=~/mame && ./ymrender LOG OUT.raw SECONDS
#   fifo_time.py LOG OUT.log    the log re-timed as rtl/ns2_ym_fifo.sv passes it
#   chsplit.py LOG CH OUT.log TMAX   one channel's writes and the global ones
MAME ?= $(HOME)/mame
Y := $(MAME)/3rdparty/ymfm/src
ymrender: ymrender.cpp
	g++ -O2 -std=c++17 -I$(Y) ymrender.cpp $(Y)/ymfm_opm.cpp -o ymrender
