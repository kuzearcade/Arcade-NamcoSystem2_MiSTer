// MAME's YM2151 (ymfm, MAME's 3rdparty copy) rendering a write log ("seconds a0
// data" lines) at its native rate (clock / 64), as s16 stereo pairs: the
// reference for the core's jt51 replay (sim/rtl/ns2_ym).
//   ymrender LOG OUT.raw SECONDS
#include "ymfm_opm.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
struct W { double t; int a0, d; };
int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: LOG OUT SECONDS\n"); return 1; }
	std::vector<W> w; FILE *f = fopen(argv[1], "r"); W x;
	while (fscanf(f, "%lf %d %d", &x.t, &x.a0, &x.d) == 3) w.push_back(x);
	fclose(f);
	ymfm::ymfm_interface intf;
	ymfm::ym2151 chip(intf);
	chip.reset();
	const double fs = 3579545.0 / 64.0;
	const long n = (long)(atof(argv[3]) * fs);
	FILE *o = fopen(argv[2], "wb");
	size_t wi = 0;
	for (long s = 0; s < n; s++) {
		double t = s / fs;
		while (wi < w.size() && w[wi].t <= t) { chip.write(w[wi].a0, w[wi].d); wi++; }
		ymfm::ym2151::output_data out;
		chip.generate(&out);
		int16_t lr[2];
		for (int c = 0; c < 2; c++) { int v = out.data[c]; lr[c] = v > 32767 ? 32767 : v < -32768 ? -32768 : v; }
		fwrite(lr, 2, 2, o);
	}
	fclose(o);
	printf("%zu writes, %ld samples\n", wi, n);
}
