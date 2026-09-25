// M1 (docs/PLAN.md): ns2_video against MAME's pictures by state injection.
//
//   ./obj_dir/Vns2_video SET TRACE_DIR [first [last [every]]]
//
// For each captured frame F (TRACE_DIR/sNNNNN.bin, tools/ns2_capture.py):
// the video RAMs and registers get state F, the palette colours state F+1's
// (NS2-2: MAME's picture F+1 is state F coloured with F+1's palette), and
// the picture is compared with MAME's pF+1.raw. A frame with register writes
// is rendered band by band as MAME drew it (tools/ns2_model.py
// render_banded): each band's registers are state F-1's plus frame F's
// writes before the band's line.
//
// The ROMs (sim/rtl/roms/SET, tools/ns2_romdump.py) are served on each
// stream in order with random acceptance and latency (MP-9's stall
// injection): STALL=0 serves at once, the default is up to 24 clocks.
#include "Vns2_video.h"
#include "Vns2_video___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>
#include <algorithm>

static std::vector<uint8_t> load(const std::string &p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) return v;
	fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
	if (fread(v.data(), 1, v.size(), f) != v.size()) v.clear();
	fclose(f);
	return v;
}

struct Block { std::string name; uint32_t addr; int words; };
static std::vector<Block> blocks;
typedef std::map<std::string, std::vector<uint16_t>> State;

static bool read_state(const std::string &trace, int F, State &st) {
	char p[512]; snprintf(p, sizeof p, "%s/s%05d.bin", trace.c_str(), F);
	auto raw = load(p);
	if (raw.empty()) return false;
	size_t off = 0;
	for (auto &b : blocks) {
		std::vector<uint16_t> w(b.words);
		for (int i = 0; i < b.words; i++, off += 2) w[i] = raw[off] << 8 | raw[off + 1];
		st[b.name] = w;
	}
	return true;
}

struct RegWrite { int line; uint32_t addr; uint16_t data, mask; };
static std::map<int, std::vector<RegWrite>> regs;
static int order(int line) { return ((line - 224) % 264 + 264) % 264; }
static const char *REGBLOCKS[] = {"tctl", "pal", "gfxctl", "rozctl"};

static State apply_writes(const State &base, const std::vector<RegWrite> &ws) {
	State n = base;
	for (auto &w : ws)
		for (auto &b : blocks) {
			bool isreg = false;
			for (auto r : REGBLOCKS) if (b.name == r) isreg = true;
			if (!isreg || !n.count(b.name)) continue;
			if (w.addr >= b.addr && w.addr < b.addr + 2 * (uint32_t)b.words) {
				uint16_t &v = n[b.name][(w.addr - b.addr) / 2];
				v = (v & ~w.mask) | (w.data & w.mask);
			}
		}
	return n;
}
static uint16_t c116(const State &s, int r) {
	auto &p = s.at("pal");
	return (p[0x1800 + 2 * r] & 0xff) << 8 | (p[0x1801 + 2 * r] & 0xff);
}

// ---------------------------------------------------------------- ROM streams
static uint64_t cyc = 0;
static int stall_max = 24;
struct Stream {
	const std::vector<uint8_t> *rom;
	int bytes;                // 8 = a burst, 1 = a byte
	std::deque<std::pair<uint64_t, uint32_t>> q;   // (ready cycle, address)
	void serve(bool req, uint32_t addr, uint8_t &ack, uint8_t &valid, uint64_t &data) {
		ack = 0; valid = 0;
		if (req && (stall_max == 0 || rand() % 4 != 0)) {
			ack = 1;
			q.push_back({cyc + 1 + (stall_max ? rand() % stall_max : 0), addr});
		}
		if (!q.empty() && q.front().first <= cyc) {
			uint64_t off = (uint64_t)q.front().second * bytes % rom->size();
			uint64_t d = 0;
			for (int i = 0; i < bytes; i++) d |= (uint64_t)(*rom)[(off + i) % rom->size()] << (8 * i);
			data = d; valid = 1;
			q.pop_front();
		}
	}
};

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET TRACE_DIR [first [last [every]]]\n"); return 1; }
	std::string set = argv[1], trace = argv[2];
	if (getenv("STALL")) stall_max = atoi(getenv("STALL"));
	std::string rd = std::string(getenv("ROMS") ? getenv("ROMS") : "../roms/") + set + "/";
	auto tiles = load(rd + "tiles.bin"), tmask = load(rd + "tmask.bin"), roz = load(rd + "roz.bin"), spr = load(rd + "sprite.bin"),
	     clut = load(rd + "clut.bin");
	if (tiles.empty() || tmask.empty() || spr.empty()) { fprintf(stderr, "ROMs missing in %s (tools/ns2_romdump.py)\n", rd.c_str()); return 1; }
	if (roz.empty()) roz.assign(8, 0xff);
	{
		FILE *f = fopen((trace + "/blocks.txt").c_str(), "r");
		char n[64]; unsigned a; int w;
		while (f && fscanf(f, "%63s %x %d", n, &a, &w) == 3) blocks.push_back({n, a, w});
		if (f) fclose(f);
		f = fopen((trace + "/regs.txt").c_str(), "r");
		int F, l; unsigned ad, d, m; char c[8];
		while (f && fscanf(f, "%d %d %x %x %x %7s", &F, &l, &ad, &d, &m, c) == 6) regs[F].push_back({l, ad, (uint16_t)d, (uint16_t)m});
		if (f) fclose(f);
	}
	int first = argc > 3 ? atoi(argv[3]) : 0, last = argc > 4 ? atoi(argv[4]) : 1 << 30, every = argc > 5 ? atoi(argv[5]) : 1;
	bool before = getenv("BEFORE_POSIRQ") != nullptr;   // init_burnforc, init_suzuk8h2

	Vns2_video *t = new Vns2_video;
	auto *r = t->rootp;
	// the board from the capture's blocks: the road means Final Lap
	bool fl = false;
	for (auto &b : blocks) if (b.name == "road") fl = true;
	t->board = fl ? 1 : 0;
	t->tile_fl2 = set.rfind("finalap2", 0) == 0 || set.rfind("finalap3", 0) == 0;
	t->spr_fl = getenv("SPR_FL") != nullptr;   // the finallap config (tools/ns2_romdata.py games())
	for (size_t i = 0; i < 256 && i < clut.size(); i++) r->ns2_video__DOT__clut[i] = clut[i];
	Stream st_tile{&tiles, 8}, st_mask{&tmask, 1}, st_roz{&roz, 8}, st_spr{&spr, 8};
	static uint32_t pic[224][288];
	int overruns = 0;
	auto tick = [&]() {
		uint8_t a, v; uint64_t d;
		st_tile.serve(t->tile_req, t->tile_addr, a, v, d); t->tile_ack = a; t->tile_valid = v; if (v) t->tile_data = d;
		st_mask.serve(t->tmask_req, t->tmask_addr, a, v, d); t->tmask_ack = a; t->tmask_valid = v; if (v) t->tmask_data = d;
		st_roz.serve(t->roz_req, t->roz_addr, a, v, d); t->roz_ack = a; t->roz_valid = v; if (v) t->roz_data = d;
		st_spr.serve(t->spr_req, t->spr_addr, a, v, d); t->spr_ack = a; t->spr_valid = v; if (v) t->spr_data = d;
		t->clk = 1; t->eval();
		if (t->out_valid && t->out_y < 224 && t->out_x < 288) pic[t->out_y][t->out_x] = t->red << 16 | t->green << 8 | t->blue;
		if (t->overrun) overruns++;
		t->clk = 0; t->eval();
		cyc++;
	};
	t->reset = 1; for (int i = 0; i < 16; i++) tick(); t->reset = 0;

	// the RAMs: VRAM from one state, palette colours from another
	auto load_vram = [&](const State &s) {
		auto &tm = s.at("tmap");
		for (int i = 0; i < 0x8000; i++) { r->ns2_video__DOT__tmap_h[i] = tm[i] >> 8; r->ns2_video__DOT__tmap_l[i] = tm[i] & 0xff; }
		auto &sp = s.at("spr");
		for (int i = 0; i < 0x2000; i++) { r->ns2_video__DOT__spr_h[i] = sp[i] >> 8; r->ns2_video__DOT__spr_l[i] = sp[i] & 0xff; }
		auto &rz = s.count("road") ? s.at("road") : s.at("roz");
		for (int i = 0; i < 0x10000; i++) { r->ns2_video__DOT__roz_h[i] = rz[i] >> 8; r->ns2_video__DOT__roz_l[i] = rz[i] & 0xff; }
	};
	auto load_colours = [&](const State &s) {
		auto &p = s.at("pal");
		for (int o = 0; o < 0x8000; o++) {
			int plane = (o & 0x1800) >> 11, col = ((o & 0x6000) >> 2) | (o & 0x7ff);
			if (plane == 0) r->ns2_video__DOT__pal_r[col] = p[o] & 0xff;
			if (plane == 1) r->ns2_video__DOT__pal_g[col] = p[o] & 0xff;
			if (plane == 2) r->ns2_video__DOT__pal_b[col] = p[o] & 0xff;
		}
	};
	// the registers, line by line: the C123 / gfx / ROZ controls of line y
	// render during line y - 1, the C116's (clip) apply while line y shows
	auto load_ctl = [&](const State &s) {
		for (int i = 0; i < 32; i++) r->ns2_video__DOT__tctl[i] = s.at("tctl")[i];
		r->ns2_video__DOT__gfx_ctrl = s.at("gfxctl")[0];
		if (s.count("rozctl")) for (int i = 0; i < 8; i++) r->ns2_video__DOT__rozctl[i] = s.at("rozctl")[i];
	};
	auto load_c116 = [&](const State &s) {
		for (int i = 0; i < 8; i++) r->ns2_video__DOT__c116[i] = c116(s, i);
	};
	// one frame, line y with the registers of states[band[y]]: from the start
	// of line 263 (line 0 renders then) to the end of line 223
	auto frame = [&](const std::vector<State> &states, const std::vector<int> &band) {
		while (!(t->vcnt == 262 && t->hcnt == 383)) tick();
		int lastv = -1;
		while (!(t->vcnt == 224 && t->hcnt == 8)) {
			if (t->hcnt == 0 && (int)t->vcnt != lastv) {
				int v = t->vcnt; lastv = v;
				int yn = v == 263 ? 0 : v + 1;
				if (yn < 224) load_ctl(states[band[yn]]);
				if (v < 224) load_c116(states[band[v]]);
			}
			tick();
		}
	};
	int total = 0, exact = 0;
	for (int F = first; F <= last; F += every) {
		State cur, nxt, prv;
		if (!read_state(trace, F, cur)) { if (F > first + 2) break; else continue; }
		char pp[512]; snprintf(pp, sizeof pp, "%s/p%05d.raw", trace.c_str(), F + 1);
		auto mame = load(pp);
		if (mame.size() != 288 * 224 * 4 || !read_state(trace, F + 1, nxt)) continue;
		load_vram(cur);
		load_colours(nxt);
		// MAME's bands (tools/ns2_model.py render_banded): band b covers lines
		// top..last with state F-1 plus frame F's writes before its line;
		// the rest has state F's registers
		std::vector<State> states{cur};
		std::vector<int> band(224, 0);
		auto wi = regs.find(F);
		if (wi != regs.end() && read_state(trace, F - 1, prv)) {
			auto ws = wi->second;
			std::stable_sort(ws.begin(), ws.end(), [](const RegWrite &a, const RegWrite &b) { return order(a.line) < order(b.line); });
			int top = 0;
			for (int s = 0; s < 224; s++) {
				std::vector<RegWrite> w;
				for (auto &x : ws) if (order(x.line) < order(s)) w.push_back(x);
				State at = apply_writes(prv, w);
				int P = (c116(at, 5) - 32) & 0xff;
				if (s == P) {
					int lastl = before ? P - 1 : P;
					if (lastl >= top) {
						states.push_back(at);
						for (int y = top; y <= lastl; y++) band[y] = states.size() - 1;
						top = lastl + 1;
					}
				}
			}
		}
		frame(states, band);
		static uint32_t out[224][288];
		memcpy(out, pic, sizeof out);
		int diff = 0, fx = -1, fy = -1;
		for (int y = 0; y < 224; y++)
			for (int x = 0; x < 288; x++) {
				const uint8_t *m = &mame[(y * 288 + x) * 4];
				uint32_t mv = m[0] | m[1] << 8 | m[2] << 16;
				if ((out[y][x] & 0xffffff) != mv) { if (!diff) { fx = x; fy = y; } diff++; }
			}
		total++; exact += diff == 0;
		if (diff) {
			const uint8_t *m = &mame[(fy * 288 + fx) * 4];
			printf("state %d vs picture %d: %d pixels differ (first at %d,%d: rtl %06x mame %06x)\n", F, F + 1, diff, fx, fy,
			       out[fy][fx] & 0xffffff, m[0] | m[1] << 8 | m[2] << 16);
		} else printf("state %d vs picture %d: 0 pixels differ\n", F, F + 1);
		fflush(stdout);
	}
	printf("%d / %d exact; line overruns %d\n", exact, total, overruns);
	delete t;
	return (exact == total && !overruns) ? 0 : 1;
}
