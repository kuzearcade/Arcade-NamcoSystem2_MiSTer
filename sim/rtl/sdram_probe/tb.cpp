// D3 bandwidth probe driver: ./obj_dir/Vprobe_top EN P0 P1 P2 P3 PATTERN [MS]
//   EN, PATTERN: 4-bit masks (bank 0 = bit 0); Pn: clocks per request at a fixed
//   cadence (0 = saturate). A stream keeps up if its backlog stays bounded: the
//   report gives the most requests ever owed and those owed at the end.
//   REPLAY=b0,b1,b2,b3 (environment): per bank, a file of word addresses to
//   replay in order and loop (tools/ns2_load.py --dump), or "-" for the pattern
// Runs MS milliseconds of 96 MHz after init, with rfsh high for the 1,500
// clocks of each 6,000-clock line (a 15.6 kHz hblank), and prints per bank the
// reads completed (64-bit bursts), the rate, the latency, bad words and model
// timing violations.
#include "Vprobe_top.h"
#include "Vprobe_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 7) { fprintf(stderr, "usage: EN P0 P1 P2 P3 PATTERN [MS]\n"); return 1; }
	Vprobe_top *t = new Vprobe_top;
	t->enable = strtol(argv[1], 0, 0);
	t->period0 = atoi(argv[2]); t->period1 = atoi(argv[3]); t->period2 = atoi(argv[4]); t->period3 = atoi(argv[5]);
	t->pattern = strtol(argv[6], 0, 0);
	double ms = argc > 7 ? atof(argv[7]) : 5.0;
	const char *names[4] = {0, 0, 0, 0};
	if (const char *rp = getenv("REPLAY")) {
		static char buf[4096]; snprintf(buf, sizeof buf, "%s", rp);
		char *save, *tok = strtok_r(buf, ",", &save);
		for (int b = 0; b < 4 && tok; b++, tok = strtok_r(0, ",", &save))
			if (strcmp(tok, "-")) {
				FILE *f = fopen(tok, "r");
				if (!f) { fprintf(stderr, "cannot open %s\n", tok); return 1; }
				unsigned a, n = 0;
				auto &rpm = t->rootp->probe_top__DOT__rp;
				while (n < (1u << 18) && fscanf(f, "%x", &a) == 1) rpm[(b << 18) + n++] = a & 0x3ffffc;
				fclose(f);
				t->replay |= 1 << b; names[b] = tok;
				(b == 0 ? t->rp_len0 : b == 1 ? t->rp_len1 : b == 2 ? t->rp_len2 : t->rp_len3) = n;
			}
	}
	auto &mem = t->rootp->probe_top__DOT__u_mem__DOT__mem;
	for (long i = 0; i < (1L << 24); i++) {
		unsigned b = i >> 22, w = i & 0x3fffff;
		mem[i] = (w & 0xffff) ^ ((((w >> 16) & 0x3f) << 10) | (b << 8) | 0x5a);
	}
	uint64_t cyc = 0;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++; t->rfsh = (cyc % 6000) < 1500; };
	t->rst = 1; for (int i = 0; i < 100; i++) tick(); t->rst = 0;
	for (int i = 0; i < 1000; i++) tick();
	while (t->init) tick();                      // init is high while the controller initialises
	uint64_t c0 = cyc, n = (uint64_t)(ms * 96000);
	if (getenv("PROBE_TRACE")) for (int i = 0; i < 200; i++) {
		tick();
		if (t->dbg_ack || t->dbg_dst || t->dbg_dok || t->dbg_rdy)
			printf("  c%4llu addr0 %06x ack %x dst %x dok %x rdy %x dout %04x\n", (unsigned long long)(cyc - c0), t->dbg_addr0, t->dbg_ack, t->dbg_dst, t->dbg_dok, t->dbg_rdy, t->dbg_dout);
	}
	while (cyc - c0 < n) tick();
	uint32_t done[4] = {t->done0, t->done1, t->done2, t->done3}, sum[4] = {t->lat_sum0, t->lat_sum1, t->lat_sum2, t->lat_sum3},
	         mx[4] = {t->lat_max0, t->lat_max1, t->lat_max2, t->lat_max3},
	         bl[4] = {t->backlog0, t->backlog1, t->backlog2, t->backlog3}, ow[4] = {t->owed0, t->owed1, t->owed2, t->owed3};
	double us = n / 96.0, total = 0;
	for (int b = 0; b < 4; b++) {
		if (!(t->enable >> b & 1)) continue;
		total += done[b] / us;
		const char *pat = names[b] ? strrchr(names[b], '/') ? strrchr(names[b], '/') + 1 : names[b] : (t->pattern >> b & 1) ? "random" : "sequential";
		printf("bank %d (%s, period %d): %8u reads, %6.2f M/s, latency avg %5.1f max %3u clk; backlog max %u, at end %u\n", b,
		       pat, b == 0 ? t->period0 : b == 1 ? t->period1 : b == 2 ? t->period2 : t->period3,
		       done[b], done[b] / us, done[b] ? (double)sum[b] / done[b] : 0.0, mx[b], bl[b], ow[b]);
	}
	printf("total %.2f M 64-bit reads/s; bad words %u; model timing violations %u\n", total, t->bad_words, t->violations);
	int rc = (t->bad_words || t->violations) ? 1 : 0;
	delete t;
	return rc;
}
