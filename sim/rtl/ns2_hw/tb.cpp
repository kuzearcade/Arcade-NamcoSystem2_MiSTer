// M3 (docs/PLAN.md): the board with its ROMs in the SDRAM (top.sv), from the
// set's download image (tools/ns2_image.py) to MAME's pictures.
//   ./obj_dir/Vtop SET TRACE_DIR [last_frame]
// TRACE_DIR: a capture (tools/ns2_capture.py: pNNNNN.raw, ports.txt); the
// board's frame F is compared with MAME's picture F, as sim/rtl/ns2_frames.
// KEY, BOARD, SPR_FL, TILE_FL2 as there; MH_WIRING, LW_WIRING the download's
// wiring; DL_SKIP0=1 skips the image's zero words outside the masks (the
// model starts at 0; the class table needs every mask word);
// PICS_DUMP=dir writes the board's pictures.
#include "Vtop.h"
#include "verilated.h"
#include "Vtop___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

static std::vector<uint8_t> load(const std::string &p) {
	std::vector<uint8_t> v; FILE *f = fopen(p.c_str(), "rb"); if (!f) return v;
	fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
	if (fread(v.data(), 1, v.size(), f) != v.size()) v.clear(); fclose(f); return v;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET TRACE_DIR [last_frame]\n"); return 1; }
	std::string set = argv[1], rd = std::string("../roms/") + set + "/", td = argv[2];
	const long last = argc > 3 ? atol(argv[3]) : 100;
	auto img = load(rd + "image.bin"), mint = load(rd + "mcu_int.bin");
	if (img.empty()) { fprintf(stderr, "no image.bin (tools/ns2_image.py)\n"); return 1; }
	std::map<std::string, unsigned> ports;
	{
		FILE *f = fopen((td + "/ports.txt").c_str(), "r");
		char n[64]; unsigned v;
		while (f && fscanf(f, "%63s %x", n, &v) == 2) ports[n] = v;
		if (f) fclose(f);
	}
	Vtop *t = new Vtop;
	uint64_t fc = 0, cyc = 0;           // fast and core clocks
	auto slow = [&]() {
		for (int h = 0; h < 2; h++) {
			t->clk_sd = 1; t->clk = (h == 0); t->eval();
			t->clk_sd = 0; t->eval();
			fc++;
		}
		cyc++;
		t->rfsh = t->hcnt >= 300;       // hblank's share (the board's raster)
	};
	auto port = [&](const char *n, unsigned d) { return ports.count(n) ? ports[n] : d; };
	t->mcub = port(":MCUB", 0xff); t->mcuc = port(":MCUC", 0xff); t->mcuh = port(":MCUH", 0xff); t->dsw = port(":DSW", 0xff);
	t->dials = port(":MCUDI0", 0xff) | port(":MCUDI1", 0xff) << 8 | port(":MCUDI2", 0xff) << 16 | port(":MCUDI3", 0xff) << 24;
	t->analog = 0;
	for (int i = 0; i < 8; i++) { char n[8]; snprintf(n, 8, ":AN%d", i); t->analog |= (uint64_t)port(n, 0xff) << (8 * i); }
	t->board = getenv("BOARD") ? atoi(getenv("BOARD")) : 0;
	t->tile_fl2 = getenv("TILE_FL2") != nullptr; t->spr_fl = getenv("SPR_FL") != nullptr;
	t->mh_wiring = getenv("MH_WIRING") != nullptr; t->lw_wiring = getenv("LW_WIRING") != nullptr;
	t->mcu_c68 = mint.size() == 32768;
	{
		unsigned mode = 0; int k[8] = {0}, v[8] = {0};
		if (const char *ks = getenv("KEY")) sscanf(ks, "%u %d %x %d %x %d %x %d %x %d %x %d %x %d %x %d %x", &mode,
		    &k[0], &v[0], &k[1], &v[1], &k[2], &v[2], &k[3], &v[3], &k[4], &v[4], &k[5], &v[5], &k[6], &v[6], &k[7], &v[7]);
		t->key_mode = mode;
		for (int i = 0; i < 8; i++) {
			uint32_t e = (k[i] ? 1u << 16 : 0) | (v[i] & 0xffff);
			for (int b = 0; b < 17; b++) if (e >> b & 1) t->key_table[(17 * i + b) / 32] |= 1u << ((17 * i + b) % 32);
		}
	}
	// the SDRAM's start, then the download (the board held in reset)
	t->rst = 1; t->reset = 1; for (int i = 0; i < 64; i++) slow(); t->rst = 0;
	while (t->sd_init) slow();
	t->dl = 1;
	const bool skip0 = getenv("DL_SKIP0") != nullptr;
	uint64_t c0 = cyc, words = 0;
	for (size_t a = 0; a < img.size(); a += 2) {
		uint16_t w = img[a] | img[a + 1] << 8;
		// (never in the masks: the tile class table is built from every word)
		if (skip0 && w == 0 && !(a >= 0x500000 && a < 0x600000)) continue;
		t->dl_addr = a; t->dl_data = w; t->dl_wr = 1; slow(); t->dl_wr = 0;
		do slow(); while (t->dl_wait);
		words++;
		if ((words & 0xfffff) == 0) { printf("  download at %06zx\n", a); fflush(stdout); }
	}
	t->dl = 0;
	// DL_VERIFY=1: the SDRAM's contents against the image (the plain regions)
	if (getenv("DL_VERIFY")) {
		auto *r = t->rootp;
		struct { const char *n; uint32_t img, len, ba, word; } reg[] = {
			{"master", 0x0000000, 0x040000, 0, 0x300000}, {"slave", 0x0040000, 0x040000, 0, 0x320000},
			{"audio", 0x0080000, 0x040000, 0, 0x340000}, {"mcu", 0x00C0000, 0x010000, 0, 0x360000},
			{"data", 0x0100000, 0x200000, 0, 0x200000}, {"c140", 0x0300000, 0x200000, 1, 0x200000},
			{"tmask", 0x0500000, 0x080000, 2, 0x200000}, {"tiles", 0x0600000, 0x400000, 2, 0x000000},
			{"roz A", 0x0E00000, 0x400000, 0, 0x000000}, {"roz B", 0x0E00000, 0x400000, 1, 0x000000}};
		for (auto &g : reg) {
			uint32_t bad = 0, first = 0;
			for (uint32_t o = 0; o < g.len; o += 2) {
				uint16_t want = img[g.img + o] | img[g.img + o + 1] << 8;
				uint16_t got = r->top__DOT__u_model__DOT__mem[(g.ba << 22) | (g.word + o / 2)];
				if (got != want) { if (!bad) first = o; bad++; }
			}
			printf("  verify %-6s %8u of %8u words differ%s", g.n, bad, g.len / 2, bad ? "" : "\n");
			if (bad) printf(" (first at +%06x: sdram %04x, image %04x)\n", first,
			                r->top__DOT__u_model__DOT__mem[(g.ba << 22) | (g.word + first / 2)], img[g.img + first] | img[g.img + first + 1] << 8);
		}
	}
	printf("download: %llu words in %llu clocks (%.1f per word); violations %u\n", (unsigned long long)words,
	       (unsigned long long)(cyc - c0), (double)(cyc - c0) / (words ? words : 1), t->violations);
	fflush(stdout);
	for (int i = 0; i < 64; i++) slow();
	// the board: MAME's time 0 is the release
	t->reset = 0;
	const uint64_t base = cyc;
	// the boot script's Start press (sim/oracle/ns2_boot.lua), as in
	// sim/rtl/ns2_frames: MAME's frames boot_start .. +5, from the release
	std::string start_port; unsigned start_mask = 0, boot_start = 300;
	for (auto &p : ports) if (p.first.rfind("start", 0) == 0) { start_port = p.first.substr(5); start_mask = p.second; }
	if (ports.count("boot_start")) boot_start = ports["boot_start"];
	const unsigned mcub0 = t->mcub, mcuc0 = t->mcuc, mcuh0 = t->mcuh;
	static uint32_t pic[224][288];
	int lastv = -1, n = 0, exact = 0;
	while ((long)((cyc - base) / 811008) <= last) {
		{
			uint64_t f = (cyc - base > 64 ? cyc - base - 64 : 0) / 811008;
			unsigned clr = (f > boot_start && f <= boot_start + 6) ? start_mask : 0;
			t->mcub = start_port == ":MCUB" ? mcub0 & ~clr : mcub0;
			t->mcuc = start_port == ":MCUC" ? mcuc0 & ~clr : mcuc0;
			t->mcuh = start_port == ":MCUH" ? mcuh0 & ~clr : mcuh0;
		}
		slow();
		if (t->out_valid && t->out_y < 224 && t->out_x < 288) pic[t->out_y][t->out_x] = t->red << 16 | t->green << 8 | t->blue;
		// STREAM_CHECK=1: every tile burst and mask byte against the image
		if (getenv("STREAM_CHECK")) {
			static std::deque<uint32_t> tq, mq; static long tbad = 0, mbad = 0, tn = 0, mn = 0;
			if (t->dbg_t_ack) tq.push_back(t->dbg_t_addr);
			if (t->dbg_m_ack) mq.push_back(t->dbg_m_addr);
			if (t->dbg_t_valid && !tq.empty()) {
				uint32_t a = tq.front(); tq.pop_front(); tn++;
				uint64_t want = 0; for (int i = 0; i < 8; i++) want |= (uint64_t)img[0x600000 + a * 8 + i] << (8 * i);
				if (want != t->dbg_t_data && tbad++ < 5) printf("tile burst %05x: got %016llx want %016llx\n", a, (unsigned long long)t->dbg_t_data, (unsigned long long)want);
			}
			if (t->dbg_m_valid && !mq.empty()) {
				uint32_t a = mq.front(); mq.pop_front(); mn++;
				if (img[0x500000 + a] != t->dbg_m_data && mbad++ < 5) printf("mask byte %05x: got %02x want %02x\n", a, t->dbg_m_data, img[0x500000 + a]);
			}
			if ((cyc & 0xffffff) == 0) printf("  streams: %ld tile bursts (%ld bad), %ld mask bytes (%ld bad)\n", tn, tbad, mn, mbad);
		}
		// MDUMP=file: the master's accesses (R/W, address, data, mask) at DTACK, to
		// diff two harnesses
		{
			static FILE *md = getenv("MDUMP") ? fopen(getenv("MDUMP"), "w") : nullptr;
			static bool md_as = false, md_pend = false; static char md_rw; static unsigned md_a, md_d, md_m;
			if (md) {
				if (t->m_as && !md_as) { md_pend = true; md_rw = t->m_rnw ? 'R' : 'W'; md_a = t->m_addr << 1; md_d = t->m_wdata;
				                         md_m = (t->m_ds & 2 ? 0xff00 : 0) | (t->m_ds & 1 ? 0xff : 0); }
				md_as = t->m_as;
				if (md_pend && t->m_dtack) { md_pend = false; fprintf(md, "%c %06x %04x %04x\n", md_rw, md_a, md_rw == 'R' ? (unsigned)t->m_rdata : md_d, md_m); }
			}
		}
		// UDUMP=file: the MCU's DPRAM writes (clock from the release, address, data)
		{
			static FILE *ud = getenv("UDUMP") ? fopen(getenv("UDUMP"), "w") : nullptr;
			static FILE *sd = getenv("SDUMP") ? fopen(getenv("SDUMP"), "w") : nullptr;
			if (sd && t->snd_wr && (t->snd_addr & 0xf000) == 0x7000) fprintf(sd, "%llu %04x %02x\n", (unsigned long long)(cyc - base), t->snd_addr, t->snd_dout);
			if (ud && t->mcu_wr && (t->mcu_addr & 0xf800) == 0x5000) fprintf(ud, "%llu %04x %02x\n", (unsigned long long)(cyc - base), t->mcu_addr, t->mcu_dout);
		}
		// UTRACE=n: the MCU's first n cycles (address, write) and how long each took
		{
			static long un = getenv("UTRACE") ? atol(getenv("UTRACE")) : 0; static uint64_t ulast = 0;
			if (un > 0 && t->mcu_cen) { printf("mcu %04x %c +%llu\n", t->mcu_addr, t->mcu_wr ? 'W' : 'R', (unsigned long long)(cyc - ulast)); ulast = cyc; un--; }
		}
		// AUDIO=1: per frame, the sound CPU's writes and the chips' peaks
		if (getenv("AUDIO")) {
			static long wr = 0, cpk = 0, ypk = 0, af = 0; static uint16_t lastpc = 0;
			if (t->snd_wr) wr++;
			if (t->c140_sample && labs((long)(int16_t)t->c140_raw_l) > cpk) cpk = labs((long)(int16_t)t->c140_raw_l);
			if (labs((long)(int16_t)t->ym_l) > ypk) ypk = labs((long)(int16_t)t->ym_l);
			lastpc = t->snd_addr;
			long f = (long)((cyc - base) / 811008);
			if (f != af) { printf("audio frame %ld: %ld sound writes, C140 peak %ld, YM peak %ld, addr %04x\n", af, wr, cpk, ypk, lastpc); wr = cpk = ypk = 0; af = f; }
		}
		static long overruns = 0, ov_frame = 0; static long ov_last_f = -1;
		if (t->overrun) {
			long f = (long)((cyc - base) / 811008);
			if (overruns++ < 5) printf("overrun at line %d (frame %ld): busy %02x\n", t->vcnt, f, t->overrun_src);
			if (f != ov_last_f) { if (ov_last_f >= 0) printf("  frame %ld: %ld overruns\n", ov_last_f, ov_frame); ov_last_f = f; ov_frame = 0; }
			ov_frame++;
		}
		if ((int)t->vcnt != lastv) {
			if (t->vcnt == 224 && cyc - base > 811008) {
				long F = (long)((cyc - base) / 811008) - 1;
				char pp[512]; snprintf(pp, sizeof pp, "%s/p%05ld.raw", td.c_str(), F);
				auto mp = load(pp);
				if (mp.size() == 288 * 224 * 4) {
					int diff = 0, fy = -1, ly = -1;
					for (int y = 0; y < 224; y++)
						for (int x = 0; x < 288; x++) {
							const uint8_t *q = &mp[(y * 288 + x) * 4];
							if ((pic[y][x] & 0xffffff) != (uint32_t)(q[0] | q[1] << 8 | q[2] << 16)) { if (!diff) fy = y; diff++; ly = y; }
						}
					n++; exact += diff == 0;
					if (diff) printf("frame %ld: %d pixels differ (lines %d-%d)\n", F, diff, fy, ly);
					fflush(stdout);
				}
				if (getenv("PICS_DUMP")) {
					snprintf(pp, sizeof pp, "%s/rtl%05ld.raw", getenv("PICS_DUMP"), F);
					FILE *df = fopen(pp, "wb"); if (df) { fwrite(pic, sizeof pic, 1, df); fclose(df); }
				}
			}
			lastv = t->vcnt;
		}
	}
	printf("pictures: %d of %d exact; SDRAM violations %u; video: busiest line %u of 3072 clocks, overrun sources %02x\n",
	       exact, n, t->violations, t->line_busy_max, t->overrun_src);
	// the caches: reads, misses, waits (clocks)
	auto *r = t->rootp;
	struct { const char *n; uint32_t rd, ms, wt; } c[] = {
		{"master", r->top__DOT__u_board__DOT__g_caches__DOT__u_mc__DOT__n_reads, r->top__DOT__u_board__DOT__g_caches__DOT__u_mc__DOT__n_miss, r->top__DOT__u_board__DOT__g_caches__DOT__u_mc__DOT__n_wait},
		{"slave", r->top__DOT__u_board__DOT__g_caches__DOT__u_sc__DOT__n_reads, r->top__DOT__u_board__DOT__g_caches__DOT__u_sc__DOT__n_miss, r->top__DOT__u_board__DOT__g_caches__DOT__u_sc__DOT__n_wait},
		{"data", r->top__DOT__u_board__DOT__g_caches__DOT__u_dc__DOT__n_reads, r->top__DOT__u_board__DOT__g_caches__DOT__u_dc__DOT__n_miss, r->top__DOT__u_board__DOT__g_caches__DOT__u_dc__DOT__n_wait},
		{"audio", r->top__DOT__u_board__DOT__g_caches__DOT__u_ac__DOT__n_reads, r->top__DOT__u_board__DOT__g_caches__DOT__u_ac__DOT__n_miss, r->top__DOT__u_board__DOT__g_caches__DOT__u_ac__DOT__n_wait},
		{"mcu", r->top__DOT__u_board__DOT__g_caches__DOT__u_uc__DOT__n_reads, r->top__DOT__u_board__DOT__g_caches__DOT__u_uc__DOT__n_miss, r->top__DOT__u_board__DOT__g_caches__DOT__u_uc__DOT__n_wait}};
	printf("filter: tiles %u (%u fetched, %.1f%%), masks %u (%u fetched, %.1f%%)\n", t->flt_t, t->flt_t_miss, t->flt_t ? 100.0 * t->flt_t_miss / t->flt_t : 0.0,
	       t->flt_m, t->flt_m_miss, t->flt_m ? 100.0 * t->flt_m_miss / t->flt_m : 0.0);
	for (auto &x : c) printf("cache %-6s %10u reads, %8u misses (%.2f%%), %10u clocks waited (%.2f%% of %llu)\n", x.n, x.rd, x.ms,
	                         x.rd ? 100.0 * x.ms / x.rd : 0.0, x.wt, 100.0 * x.wt / (cyc - base), (unsigned long long)(cyc - base));
	delete t;
	return 0;
}
