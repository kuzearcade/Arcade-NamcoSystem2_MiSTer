// ns2_sdram (M3) against the burst SDRAM model: the download writes a
// pattern into all four banks, then each bank reads random bursts from the
// core's clock (two requests in flight), every word checked.
//   ./obj_dir/Vtop [words_per_bank] [reads_per_bank]
#include "Vtop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>

static uint16_t pat(int b, uint32_t a) { uint32_t x = (a * 2654435761u) ^ (b * 0x9e3779b9u) ^ (a >> 7); return x ^ (x >> 16); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const uint32_t W = argc > 1 ? atol(argv[1]) : 16384, N = argc > 2 ? atol(argv[2]) : 20000;
	Vtop *t = new Vtop;
	uint64_t fc = 0;                       // fast cycles
	// one fast period; the slow clock rises with every even fast edge
	auto fast = [&]() {
		t->clk_sd = 1; t->clk = (fc % 2 == 0); t->eval();
		t->clk_sd = 0; t->eval();
		fc++;
		t->rfsh = (fc % 6144) < 1536;      // hblank's share
	};
	auto slow = [&]() { fast(); fast(); }; // one core clock
	t->rst = 1; for (int i = 0; i < 64; i++) slow(); t->rst = 0;
	while (t->init) slow();
	printf("init done at %llu fast cycles\n", (unsigned long long)fc);
	// the download
	t->prog_en = 1; t->prog_dsn = 0;
	uint64_t f0 = fc;
	for (int b = 0; b < 4; b++)
		for (uint32_t a = 0; a < W; a++) {
			t->prog_ba = b; t->prog_addr = a; t->prog_din = pat(b, a);
			bool s = t->prog_ack_t; t->prog_req_t = !t->prog_req_t;
			int to = 0;
			while (t->prog_ack_t == s) { slow(); if (++to > 1000) { printf("write timeout\n"); return 1; } }
		}
	printf("download: %u words in %llu fast cycles (%.1f per word)\n", 4 * W, (unsigned long long)(fc - f0), (double)(fc - f0) / (4 * W));
	t->prog_en = 0; for (int i = 0; i < 16; i++) slow();
	// the reads: a request whenever the bank's FIFO has room, up to MAXQ in flight
	const int MAXQ = getenv("MAXQ") ? atoi(getenv("MAXQ")) : 6;
	std::deque<uint32_t> want[4];
	uint32_t issued[4] = {0}, done[4] = {0}, bad = 0;
	uint8_t val_seen = t->valid_t;
	uint64_t r0 = fc;
	srand(1);
	while (done[0] < N || done[1] < N || done[2] < N || done[3] < N) {
		t->push = 0;
		for (int b = 0; b < 4; b++) {
			if (((t->valid_t ^ val_seen) >> b) & 1) {
				val_seen ^= 1 << b;
				uint64_t d = b == 0 ? t->data0 : b == 1 ? t->data1 : b == 2 ? t->data2 : t->data3;
				if (want[b].empty()) { printf("bank %d: a burst nobody asked for\n", b); bad++; continue; }
				uint32_t a = want[b].front(); want[b].pop_front(); done[b]++;
				for (int k = 0; k < 4; k++)
					if (((d >> (16 * k)) & 0xffff) != pat(b, a + k)) { if (bad++ < 5) printf("bad: bank %d addr %06x word %d: %04llx want %04x\n", b, a, k, (unsigned long long)((d >> (16 * k)) & 0xffff), pat(b, a + k)); }
			}
			if (!((t->req_full >> b) & 1) && (int)want[b].size() < MAXQ && issued[b] < N) {
				uint32_t a = (rand() % (W / 4)) * 4;
				want[b].push_back(a); issued[b]++;
				switch (b) { case 0: t->addr0 = a; break; case 1: t->addr1 = a; break; case 2: t->addr2 = a; break; default: t->addr3 = a; }
				t->push |= 1 << b;
			}
		}
		slow();
		if (fc - r0 > 400000000ULL) { printf("timeout\n"); break; }
	}
	printf("reads: %u bursts, %u bad; %llu fast cycles (%.1f per burst per bank); violations %u\n", 4 * N, bad,
	       (unsigned long long)(fc - r0), (double)(fc - r0) / N, t->violations);
	bool fail = bad || t->violations;
	delete t;
	return fail;
}
