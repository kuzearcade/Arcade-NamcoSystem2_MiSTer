// NS2-29: ns2_fir4 (CHIP, SPACE from the Makefile) fed a recorded stream, a
// sample a strobe; strobes spaced as on the board (the C140 every 2304
// clocks; jt51 every 878 or 879, plus random extra gaps up to 40 clocks),
// and every phase's output compared with the integer model: out =
// sat((sum_k coef(4k + p) * x[n - k]) >>> 17), k = 0..31.
#include "Vns2_fir4.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
static std::vector<long> load_coefs(const char *vh) {
	std::vector<long> c(128, 0); FILE *f = fopen(vh, "r"); char l[256];
	while (fgets(l, sizeof l, f)) {
		int i; char sg; long v; const char *p = strstr(l, "7'd");
		if (!p || sscanf(p, "7'd%d", &i) != 1) continue;
		const char *q = strstr(l, "18'sd"); if (!q) continue;
		sg = q[-1]; sscanf(q + 5, "%ld", &v); c[i] = sg == '-' ? -v : v;
	}
	fclose(f); return c;
}
static int16_t sat(long long v) { v >>= 17; return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: IN.raw SAMPLES\n"); return 1; }
	auto c = load_coefs(CHIP == 1 ? "../../../rtl/ns2_ym_fir_coef.vh" : "../../../rtl/ns2_c140_fir_coef.vh");
	std::vector<int16_t> in; { FILE *f = fopen(argv[1], "rb"); int16_t lr[2]; long n = atol(argv[2]);
		while ((long)in.size() / 2 < n && fread(lr, 2, 2, f) == 2) { in.push_back(lr[0]); in.push_back(lr[1]); } fclose(f); }
	Vns2_fir4 *t = new Vns2_fir4;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->reset = 1; t->in_stb = 0; for (int i = 0; i < 8; i++) tick(); t->reset = 0;
	std::vector<int16_t> hl(32, 0), hr(32, 0);   // the model's history, newest first
	long checked = 0, bad = 0; uint64_t acc = 0; srand(1);
	size_t ns = in.size() / 2;
	for (size_t n = 0; n < ns; n++) {
		// the gap before this sample
		long gap = CHIP == 1 ? ((acc += 878798) >= 1000000 ? (acc -= 1000000, 879) : 878) + rand() % 41 : 2304;
		t->in_stb = 1; t->in_l = in[2 * n]; t->in_r = in[2 * n + 1]; tick(); t->in_stb = 0;
		for (int k = 31; k > 0; k--) { hl[k] = hl[k - 1]; hr[k] = hr[k - 1]; }
		hl[0] = in[2 * n]; hr[0] = in[2 * n + 1];
		for (long clk = 1; clk < gap; clk++) {
			tick();
			// phase p's output is complete 40 clocks into its slot
			for (int p = 0; p < 4; p++) if (clk == p * SPACE + 40) {
				long long sl = 0, sr = 0;
				for (int k = 0; k < 32; k++) { sl += (long long)c[4 * k + p] * hl[k]; sr += (long long)c[4 * k + p] * hr[k]; }
				int16_t el = sat(sl), er = sat(sr);
				checked++;
				if ((int16_t)t->out_l != el || (int16_t)t->out_r != er) {
					if (bad++ < 5) printf("sample %zu phase %d: rtl %d %d model %d %d\n", n, p, (int16_t)t->out_l, (int16_t)t->out_r, el, er);
				}
			}
		}
	}
	printf("CHIP %d: %ld outputs checked, %ld differ\n", CHIP, checked, bad);
	return bad != 0;
}
