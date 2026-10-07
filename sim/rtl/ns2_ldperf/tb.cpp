// ns2_ldperf: a DDR3-mode download of a LEN-byte image (a fixed pseudo-random
// pattern) replayed through ddr_rom_load, ns2_mem and ns2_sdram into the SDRAM
// model. Prints clk (sys) cycles per image word and an FNV hash of the SDRAM.
//   ./obj_dir/Vtop [LEN_hex] [board] [mh] [lw]
#include "Vtop.h"
#include "Vtop___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
static Vtop *t;
static uint64_t fc = 0;                       // clk_sd (fast) cycles
static inline uint8_t img(uint64_t a) { uint64_t x = a * 0x9E3779B97F4A7C15ull; x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ull; return (uint8_t)(x >> 32); }
// one clk_sd period; clk rises on every other clk_sd rise
static int lat = -1; static uint32_t lat_addr;
static void fast() {
	t->clk_sd = 1; if ((fc & 1) == 0) t->clk = 1; t->eval();
	// DDR3 port model on clk_sd (= clk_ddr): one read in flight, 20 clocks
	t->ddr_dout_ready = 0;
	if (lat > 0) lat--;
	else if (lat == 0) { uint64_t d = 0; uint64_t b = (uint64_t)(lat_addr - 0x06000000u) * 8; for (int k = 0; k < 8; k++) d |= (uint64_t)img(b + k) << (8 * k); t->ddr_dout = d; t->ddr_dout_ready = 1; lat = -1; }
	if (t->ddr_rd && lat < 0) { lat = 20; lat_addr = t->ddr_addr; }
	t->clk_sd = 0; if ((fc & 1) == 1) t->clk = 0; t->eval();
	fc++;
}
static void slow() { fast(); fast(); }
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	uint32_t LEN = argc > 1 ? strtoul(argv[1], 0, 16) : 0x1200000;
	t = new Vtop;
	t->board = argc > 2 ? atoi(argv[2]) : 0; t->mh_wiring = argc > 3 ? atoi(argv[3]) : 0; t->lw_wiring = argc > 4 ? atoi(argv[4]) : 0;
	t->rst = 1; for (int i = 0; i < 100; i++) slow(); t->rst = 0;
	for (int i = 0; i < 12000; i++) slow();          // the controller's init
	t->h_addr = LEN; t->h_download = 1; for (int i = 0; i < 100; i++) slow();
	t->h_download = 0; t->h_addr = LEN + 2;
	slow(); slow();
	if (!t->active) { printf("no replay\n"); return 1; }
	uint64_t f0 = fc;
	uint64_t c_sdidle = 0, c_starve = 0, c_wait = 0, c_all = 0;
	auto &R = *t->rootp;
	int trace = 0;
	while (t->active) {
		if (getenv("TRACE") && c_all > 20000 && trace < 60) {
			for (int h = 0; h < 2; h++) {
				fast(); trace++;
				printf("sd %3d: req %d seen %d wr %d ack %d rdy %d busy %d cmd %x | ack_t %d wait_ack %d\n", trace,
					R.top__DOT__prog_req_t, R.top__DOT__u_sd__DOT__prog_seen, R.top__DOT__u_sd__DOT__prog_wr,
					R.top__DOT__u_sd__DOT__prog_ack, R.top__DOT__u_sd__DOT__prog_rdy, R.top__DOT__u_sd__DOT__prog_busy,
					R.top__DOT__u_sd__DOT__u_ctl__DOT__cmd, R.top__DOT__prog_ack_t, R.top__DOT__mem__DOT__wait_ack);
			}
			c_all++; continue;
		}
		slow(); c_all++;
		if (!R.top__DOT__u_sd__DOT__prog_busy && !R.top__DOT__mem__DOT__wait_ack) c_sdidle++;
		if (!R.top__DOT__ld__DOT__cur_v) c_starve++;
		if (R.top__DOT__mem__DOT__busy) c_wait++;
	}
	printf("of %llu clocks: SDRAM prog idle %.1f%%, replay without data %.1f%%, ns2_mem busy %.1f%%\n", (unsigned long long)c_all,
		100.0 * c_sdidle / c_all, 100.0 * c_starve / c_all, 100.0 * c_wait / c_all);
	uint64_t f1 = fc;
	for (int i = 0; i < 200; i++) slow();
	uint32_t words = LEN / 2;
	printf("len %06x: %u words in %llu clk cycles (%.2f per word, %.3f s at 49.152 MHz), writes seen %u, violations %u\n",
		LEN, words, (unsigned long long)((f1 - f0) / 2), (double)(f1 - f0) / 2 / words, (double)(f1 - f0) / 2 / 49.152e6, t->n_wr, t->violations);
	uint64_t h = 1469598103934665603ull;
	auto &mem = t->rootp->top__DOT__u_mem__DOT__mem;
	for (uint32_t i = 0; i < 16u * 1024 * 1024; i++) { h ^= mem[i]; h *= 1099511628211ull; }
	printf("sdram hash %016llx\n", (unsigned long long)h);
	delete t; return 0;
}
