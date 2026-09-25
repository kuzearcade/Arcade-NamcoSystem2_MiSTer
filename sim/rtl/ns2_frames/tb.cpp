// M2 (docs/PLAN.md): the whole board (rtl/ns2_board.sv) from power-on, the
// ROMs as arrays (sim/rtl/roms/SET, tools/ns2_romdump.py).
//   ./obj_dir/Vns2_board SET BUS_TRACE_DIR [max_accesses]
// Compares a 68000's accesses with MAME's (sim/oracle/ns2_bustrace.lua:
// <cpu>_bus.txt, ports.txt), in order, until the first difference; CPU=slave
// compares the slave's (default: the master's, maincpu).
// The key table comes from KEY="mode t0 v0 t1 v1 ..." (tools/ns2_keys.py).
#include "Vns2_board.h"
#include "Vns2_board___024root.h"
#include "verilated.h"
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
static uint64_t cyc = 0;
struct Stream {
	const std::vector<uint8_t> *rom; int bytes;
	std::deque<std::pair<uint64_t, uint32_t>> q;
	void serve(bool req, uint32_t addr, uint8_t &ack, uint8_t &valid, uint64_t &data) {
		ack = 0; valid = 0;
		if (req) { ack = 1; q.push_back({cyc + 3, addr}); }
		if (!q.empty() && q.front().first <= cyc) {
			uint64_t off = (uint64_t)q.front().second * bytes % rom->size(), d = 0;
			for (int i = 0; i < bytes; i++) d |= (uint64_t)(*rom)[(off + i) % rom->size()] << (8 * i);
			data = d; valid = 1; q.pop_front();
		}
	}
};
struct Acc { char rw; unsigned addr, data, mask; int frame; };

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET BUS_TRACE_DIR [max]\n"); return 1; }
	std::string set = argv[1], rd = std::string("../roms/") + set + "/", td = argv[2];
	auto mrom = load(rd + "maincpu.bin"), srom = load(rd + "slave.bin"), drom = load(rd + "data.bin"),
	     arom = load(rd + "audio.bin"), irom = load(rd + "mcu_int.bin"), erom = load(rd + "mcu_ext.bin"),
	     tiles = load(rd + "tiles.bin"), tmask = load(rd + "tmask.bin"), roz = load(rd + "roz.bin"),
	     spr = load(rd + "sprite.bin"), nv = load(rd + "nvram.bin");
	if (mrom.empty() || srom.empty() || irom.empty() || erom.empty()) { fprintf(stderr, "ROMs missing (tools/ns2_romdump.py)\n"); return 1; }
	if (roz.empty()) roz.assign(8, 0xff);
	const bool slave = getenv("CPU") && !strcmp(getenv("CPU"), "slave");
	std::vector<Acc> mame;
	{
		FILE *f = fopen((td + "/" + (slave ? "slave" : "maincpu") + "_bus.txt").c_str(), "r");
		char rw; unsigned a, d, m; int fr;
		while (f && fscanf(f, " %c %x %x %x %d", &rw, &a, &d, &m, &fr) == 5) mame.push_back({rw, a, d, m, fr});
		if (f) fclose(f);
	}
	std::map<std::string, unsigned> ports;
	{
		FILE *f = fopen((td + "/ports.txt").c_str(), "r");
		char n[64]; unsigned v;
		while (f && fscanf(f, "%63s %x", n, &v) == 2) ports[n] = v;
		if (f) fclose(f);
	}
	size_t maxn = argc > 3 ? atol(argv[3]) : mame.size();

	Vns2_board *t = new Vns2_board;
	auto *r = t->rootp;
	for (size_t i = 0; i < mrom.size() / 2; i++) r->ns2_board__DOT__mrom[i] = mrom[2 * i] << 8 | mrom[2 * i + 1];
	for (size_t i = 0; i < srom.size() / 2; i++) r->ns2_board__DOT__srom[i] = srom[2 * i] << 8 | srom[2 * i + 1];
	for (size_t i = 0; i < drom.size() / 2 && i < (1u << 20); i++) r->ns2_board__DOT__drom[i] = drom[2 * i] << 8 | drom[2 * i + 1];
	for (size_t i = 0; i < (1u << 18); i++) r->ns2_board__DOT__arom[i] = arom.empty() ? 0xff : arom[i % arom.size()];
	for (size_t i = 0; i < 8192; i++) r->ns2_board__DOT__irom[i] = irom[i];
	for (size_t i = 0; i < 32768; i++) r->ns2_board__DOT__erom[i] = erom[i];
	for (size_t i = 0; i < 8192; i++) r->ns2_board__DOT__u_main__DOT__u_master__DOT__eep[i] = nv.size() == 8192 ? nv[i] : 0xff;
	t->board = 0; t->tile_fl2 = 0; t->spr_fl = 0;
	auto port = [&](const char *n, unsigned d) { return ports.count(n) ? ports[n] : d; };
	t->mcub = port(":MCUB", 0xff); t->mcuc = port(":MCUC", 0xff); t->mcuh = port(":MCUH", 0xff); t->dsw = port(":DSW", 0xff);
	t->dials = port(":MCUDI0", 0xff) | port(":MCUDI1", 0xff) << 8 | port(":MCUDI2", 0xff) << 16 | port(":MCUDI3", 0xff) << 24;
	t->analog = 0;
	for (int i = 0; i < 8; i++) { char n[8]; snprintf(n, 8, ":AN%d", i); t->analog |= (uint64_t)port(n, 0xff) << (8 * i); }
	// the key table
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
	Stream st_tile{&tiles, 8}, st_mask{&tmask, 1}, st_roz{&roz, 8}, st_spr{&spr, 8};

	size_t mi = 0; bool bad = false; bool as_d = false; unsigned frame = 0; int lastv = -1;
	Acc pend{}; bool have_pend = false;
	auto tick = [&]() {
		uint8_t a, v; uint64_t d;
		st_tile.serve(t->tile_req, t->tile_addr, a, v, d); t->tile_ack = a; t->tile_valid = v; if (v) t->tile_data = d;
		st_mask.serve(t->tmask_req, t->tmask_addr, a, v, d); t->tmask_ack = a; t->tmask_valid = v; if (v) t->tmask_data = d;
		st_roz.serve(t->roz_req, t->roz_addr, a, v, d); t->roz_ack = a; t->roz_valid = v; if (v) t->roz_data = d;
		st_spr.serve(t->spr_req, t->spr_addr, a, v, d); t->spr_ack = a; t->spr_valid = v; if (v) t->spr_data = d;
		t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
	};
	t->reset = 1; for (int i = 0; i < 64; i++) tick(); t->reset = 0;
	while (mi < maxn && !bad && cyc < 4000000000ULL) {
		tick();
		if ((int)t->vcnt != lastv) { if (t->vcnt == 224) frame++; lastv = t->vcnt; }
		// a bus cycle: its address at AS, its data at DTACK
		bool as = slave ? t->s_as : t->m_as, rnw = slave ? t->s_rnw : t->m_rnw;
		unsigned ds = slave ? t->s_ds : t->m_ds;
		if (as && !as_d) {
			pend = {rnw ? 'R' : 'W', (unsigned)(slave ? t->s_addr : t->m_addr) << 1, rnw ? 0u : (slave ? t->s_wdata : t->m_wdata),
			        (unsigned)((ds & 2 ? 0xff00 : 0) | (ds & 1 ? 0x00ff : 0)), (int)frame};
			have_pend = true;
		}
		as_d = as;
		if (have_pend && (slave ? t->s_dtack : t->m_dtack)) {
			have_pend = false;
			if (pend.rw == 'R') pend.data = slave ? t->s_rdata : t->m_rdata;
			const Acc &m = mame[mi];
			unsigned mk = m.mask & pend.mask;
			if (m.rw != pend.rw || m.addr != pend.addr || ((m.data ^ pend.data) & mk) || m.mask != pend.mask) {
				printf("access %zu (rtl frame %u, mame frame %d): rtl %c %06x %04x %04x, mame %c %06x %04x %04x\n", mi, frame, m.frame,
				       pend.rw, pend.addr, pend.data, pend.mask, m.rw, m.addr, m.data, m.mask);
				printf("  mame before:"); for (size_t k = mi > 5 ? mi - 5 : 0; k < mi; k++) printf(" %c%06x:%04x", mame[k].rw, mame[k].addr, mame[k].data); printf("\n");
				printf("  mame after: "); for (size_t k = mi; k < mi + 5 && k < mame.size(); k++) printf(" %c%06x:%04x", mame[k].rw, mame[k].addr, mame[k].data); printf("\n");
				bad = true;
			}
			mi++;
		}
	}
	printf("%zu of %zu %s accesses matched (%llu clocks, frame %u)%s\n", bad ? mi - 1 : mi, maxn, slave ? "slave" : "master",
	       (unsigned long long)cyc, frame, (!bad && mi >= maxn) ? ": ALL MATCH" : "");
	delete t;
	return bad ? 1 : 0;
}
