// NS2-26: the YM2151 path (ns2_ym_fifo + jt51, top.sv) against MAME: MAME's
// YM2151 writes (a log of "seconds a0 data" lines, a tap at the sound CPU's
// 0x4000-0x4001) replayed at their times in clk_sys (49.152 MHz) clocks;
// jt51's xleft/xright written at each sample (55.93 kHz) as s16 pairs, to be
// compared with MAME's YM2151 alone (NS2_SND_ISO=ym).
//   make && ./obj_dir/Vtop LOG OUT.raw SECONDS
#include "Vtop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 4) { fprintf(stderr, "usage: LOG OUT SECONDS\n"); return 1; }
	struct W { uint64_t clk; int a0, d; };
	std::vector<W> w;
	FILE *f = fopen(argv[1], "r"); double t; int a, d;
	while (fscanf(f, "%lf %d %d", &t, &a, &d) == 3) w.push_back({(uint64_t)(t * 49152000.0 + 0.5), a, d});
	fclose(f);
	uint64_t end = (uint64_t)(atof(argv[3]) * 49152000.0);
	FILE *o = fopen(argv[2], "wb");
	Vtop *y = new Vtop;
	y->reset = 1; for (int i = 0; i < 2000; i++) { y->clk = 0; y->eval(); y->clk = 1; y->eval(); }
	y->reset = 0;
	size_t wi = 0; int ps = 0; long ns = 0;
	for (uint64_t c = 0; c < end; c++) {
		y->we = 0;
		if (wi < w.size() && w[wi].clk <= c) { y->we = 1; y->a0 = w[wi].a0; y->din = w[wi].d; wi++; }
		y->clk = 0; y->eval(); y->clk = 1; y->eval();
		if (y->sample && !ps) { int16_t lr[2] = {(int16_t)y->xleft, (int16_t)y->xright}; fwrite(lr, 2, 2, o); ns++; }
		ps = y->sample;
	}
	fclose(o);
	printf("%zu writes, %ld samples\n", wi, ns);
}
