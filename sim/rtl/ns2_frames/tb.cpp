// M2 (docs/PLAN.md): the whole board (rtl/ns2_board.sv) from power-on, the
// ROMs as arrays (sim/rtl/roms/SET, tools/ns2_romdump.py).
//   ./obj_dir/Vns2_board SET BUS_TRACE_DIR [max_accesses]
// Compares a 68000's accesses with MAME's (sim/oracle/ns2_bustrace.lua:
// <cpu>_bus.txt, ports.txt), in order, until the first difference; CPU=slave
// compares the slave's (default: the master's, maincpu); CPU=audiocpu or
// CPU=mcu compares the 6809's or the MCU's writes (a trace with MP_WONLY=1);
// DPONLY=1 keeps the DPRAM writes only (M2's gate: the MCU's DPRAM writes).
// CPU=c140 compares the C140's samples (its mixer sums) with TRACE/c140.raw,
// MAME's NS2_C140_DUMP (tools/mame-patches/ns2-oracle.patch).
// The key table comes from KEY="mode t0 v0 t1 v1 ..." (tools/ns2_keys.py).
// Diagnostics (a trace with MP_TIME=1 has MAME's times):
//   TIMES=n       every n accesses, the RTL's clock against MAME's
//   DELTA=i       from access i, where the offset from MAME's time changes
//                 (at reads: a write is stamped at its data strobe); DSHOW caps it
//   WTIMES=n      write modes: where the offset changes by more than n clocks
//   NOSTOP=1      report every difference instead of stopping at the first
//   DBGVEC=1      the MCU's vector fetches; MCUDUMP=n its addresses for n
//                 clocks from its release
#include "Vns2_board.h"
#include "Vns2_board___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
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
struct Acc { char rw; unsigned addr, data, mask; int frame; double t; };

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET BUS_TRACE_DIR [max]\n"); return 1; }
	std::string set = argv[1], rd = std::string("../roms/") + set + "/", td = argv[2];
	auto mrom = load(rd + "maincpu.bin"), srom = load(rd + "slave.bin"), drom = load(rd + "data.bin"),
	     arom = load(rd + "audio.bin"), irom = load(rd + "mcu_int.bin"), erom = load(rd + "mcu_ext.bin"),
	     tiles = load(rd + "tiles.bin"), tmask = load(rd + "tmask.bin"), roz = load(rd + "roz.bin"),
	     spr = load(rd + "sprite.bin"), nv = load(rd + "nvram.bin"), vro = load(rd + "c140.bin"),
	     c169 = load(rd + "c169.bin"), c169m = load(rd + "c169mask.bin"), c355 = load(rd + "c355.bin"), clut = load(rd + "clut.bin");
	if (c169.empty()) c169.assign(8, 0);
	if (c169m.empty()) c169m.assign(8, 0);
	if (spr.empty()) spr = c355;                      // the C355 boards: their sprites on the same stream
	if (spr.empty()) spr.assign(8, 0);
	if (mrom.empty() || srom.empty() || irom.empty() || erom.empty()) { fprintf(stderr, "ROMs missing (tools/ns2_romdump.py)\n"); return 1; }
	if (roz.empty()) roz.assign(8, 0xff);
	const std::string cpu = getenv("CPU") ? getenv("CPU") : "maincpu";
	// DPONLY=1: only the writes to the DPRAM (the 6809's 7000-77ff, the MCU's 5000-57ff)
	const bool dponly = getenv("DPONLY") != nullptr;
	auto in_dp = [&](unsigned a) { return cpu == "audiocpu" ? (a & 0xf000) == 0x7000 : (a & 0xf800) == 0x5000; };
	const bool slave = cpu == "slave", wonly = cpu == "audiocpu" || cpu == "mcu", snd = cpu == "audiocpu";
	std::vector<Acc> mame;
	{
		FILE *f = fopen((td + "/" + cpu + "_bus.txt").c_str(), "r");
		// an optional sixth column: MAME's time in clocks (MP_TIME=1)
		char line[128], rw; unsigned a, d, m; int fr; double tm;
		while (f && fgets(line, sizeof line, f)) {
			int n = sscanf(line, " %c %x %x %x %d %lf", &rw, &a, &d, &m, &fr, &tm);
			if (n >= 5 && !(getenv("DPONLY") && (getenv("CPU") && !strcmp(getenv("CPU"), "audiocpu") ? (a & 0xf000) != 0x7000 : (a & 0xf800) != 0x5000)))
				mame.push_back({rw, a, d, m, fr, n == 6 ? tm : -1});
		}
		if (f) fclose(f);
	}
	// CPU=c140: the C140's mixer sums against MAME's (NS2_C140_DUMP, tools/mame-patches)
	std::vector<int16_t> craw;
	if (cpu == "c140") {
		std::string fn = td + "/c140.raw";
		FILE *f = fopen(fn.c_str(), "rb");
		if (f) { fseek(f, 0, SEEK_END); craw.resize(ftell(f) / 2); fseek(f, 0, SEEK_SET); if (fread(craw.data(), 2, craw.size(), f) != craw.size()) craw.clear(); fclose(f); }
		if (craw.empty()) { fprintf(stderr, "no %s\n", fn.c_str()); return 1; }
		for (size_t i = 0; i < craw.size() / 2; i++) mame.push_back({'S', 0, (unsigned)(uint16_t)craw[2 * i] << 16 | (uint16_t)craw[2 * i + 1], 0, 0, -1});
	}
	std::map<std::string, unsigned> ports;
	{
		FILE *f = fopen((td + "/ports.txt").c_str(), "r");
		char n[64]; unsigned v;
		while (f && fscanf(f, "%63s %x", n, &v) == 2) ports[n] = v;
		if (f) fclose(f);
	}
	const size_t times = getenv("TIMES") ? atol(getenv("TIMES")) : 0;
	size_t maxn = argc > 3 ? atol(argv[3]) : mame.size();

	Vns2_board *t = new Vns2_board;
	auto *r = t->rootp;
	for (size_t i = 0; i < mrom.size() / 2; i++) r->ns2_board__DOT__g_arrays__DOT__mrom[i] = mrom[2 * i] << 8 | mrom[2 * i + 1];
	for (size_t i = 0; i < srom.size() / 2; i++) r->ns2_board__DOT__g_arrays__DOT__srom[i] = srom[2 * i] << 8 | srom[2 * i + 1];
	for (size_t i = 0; i < drom.size() / 2 && i < (1u << 20); i++) r->ns2_board__DOT__g_arrays__DOT__drom[i] = drom[2 * i] << 8 | drom[2 * i + 1];
	for (size_t i = 0; i < (1u << 18); i++) r->ns2_board__DOT__g_arrays__DOT__arom[i] = arom.empty() ? 0xff : arom[i % arom.size()];
	for (size_t i = 0; i < vro.size() / 2 && i < (1u << 20); i++) r->ns2_board__DOT__g_arrays__DOT__vrom[i] = vro[2 * i] << 8 | vro[2 * i + 1];
	// the MCU: the C65's internal ROM (8 KB) or the C68's c68.bin (32 KB)
	for (size_t i = 0; i < irom.size() && i < 32768; i++) r->ns2_board__DOT__g_arrays__DOT__irom[i] = irom[i];
	t->mcu_c68 = irom.size() == 32768;
	for (size_t i = 0; i < 32768; i++) r->ns2_board__DOT__g_arrays__DOT__erom[i] = erom[i];
	for (size_t i = 0; i < 8192; i++) r->ns2_board__DOT__u_main__DOT__u_master__DOT__eep[i] = nv.size() == 8192 ? nv[i] : 0xff;
	// the graphics board and the Final Lap variants (tools/ns2_romdata.py's
	// config: BOARD 0 standard, 1 Final Lap, 2 Metal Hawk, 3 Steel Gunner 2,
	// 4 Suzuka 8 Hours, 5 Lucky & Wild; SPR_FL, TILE_FL2)
	t->board = getenv("BOARD") ? atoi(getenv("BOARD")) : 0;
	t->tile_fl2 = getenv("TILE_FL2") != nullptr; t->spr_fl = getenv("SPR_FL") != nullptr;
	for (size_t i = 0; i < 256 && i < clut.size(); i++) r->ns2_board__DOT__u_video__DOT__clut[i] = clut[i];
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
	// the boot script's Start press (sim/oracle/ns2_boot.lua): set in MAME's
	// frames boot_start .. +5, read from the next frame's input update (a
	// frame being 811008 clocks from power-on)
	std::string start_port; unsigned start_mask = 0, boot_start = 300;
	for (auto &p : ports) if (p.first.rfind("start", 0) == 0) { start_port = p.first.substr(5); start_mask = p.second; }
	if (ports.count("boot_start")) boot_start = ports["boot_start"];
	const unsigned mcub0 = t->mcub, mcuc0 = t->mcuc, mcuh0 = t->mcuh;
	auto inputs = [&]() {
		uint64_t f = (cyc > 64 ? cyc - 64 : 0) / 811008;
		unsigned clr = (f > boot_start && f <= boot_start + 6) ? start_mask : 0;
		t->mcub = start_port == ":MCUB" ? mcub0 & ~clr : mcub0;
		// STALL=period,len: the master's ROM "misses" for len clocks every period (M3's caches, in M2)
		{ static long sp = getenv("STALL") ? atol(getenv("STALL")) : 0, sl = getenv("STALL") && strchr(getenv("STALL"), ',') ? atol(strchr(getenv("STALL"), ',') + 1) : 0;
		  t->dbg_stall = sp && (long)(cyc % sp) < sl; }
		t->mcuc = start_port == ":MCUC" ? mcuc0 & ~clr : mcuc0;
		t->mcuh = start_port == ":MCUH" ? mcuh0 & ~clr : mcuh0;
	};
	Stream st_tile{&tiles, 8}, st_mask{&tmask, 1}, st_roz{&roz, 8}, st_spr{&spr, 8}, st_c169{&c169, 8}, st_c169m{&c169m, 8};   // the mask: the burst holding the byte

	size_t mi = 0; bool bad = false; bool as_d = false; unsigned frame = 0; int lastv = -1;
	Acc pend{}; bool have_pend = false; uint64_t pend_cyc = 0;
	auto tick = [&]() {
		uint8_t a, v; uint64_t d;
		st_tile.serve(t->tile_req, t->tile_addr, a, v, d); t->tile_ack = a; t->tile_valid = v; if (v) t->tile_data = d;
		st_mask.serve(t->tmask_req, t->tmask_addr, a, v, d); t->tmask_ack = a; t->tmask_valid = v; if (v) t->tmask_data = d;
		st_roz.serve(t->roz_req, t->roz_addr, a, v, d); t->roz_ack = a; t->roz_valid = v; if (v) t->roz_data = d;
		st_spr.serve(t->spr_req, t->spr_addr, a, v, d); t->spr_ack = a; t->spr_valid = v; if (v) t->spr_data = d;
		st_c169.serve(t->c169_req, t->c169_addr, a, v, d); t->c169_ack = a; t->c169_valid = v; if (v) t->c169_data = d;
		st_c169m.serve(t->c169m_req, t->c169m_addr >> 3, a, v, d); t->c169m_ack = a; t->c169m_valid = v; if (v) t->c169m_data = d;
		if ((cyc & 1023) == 0) inputs();
		t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
	};
	t->reset = 1; for (int i = 0; i < 64; i++) tick(); t->reset = 0;
	// PICS=dir: the board's pictures against MAME's (dir/pNNNNN.raw, BGRA,
	// sim/oracle/ns2_capture.lua): the lines of MAME's frame F are those
	// drawn before line 224 at time (F + 1) * 811008. PICS_TO=F stops there;
	// PICS_DUMP=dir writes the RTL's (rtlNNNNN.raw, u32 0x00RRGGBB).
	const char *pics = getenv("PICS");
	const long pics_to = getenv("PICS_TO") ? atol(getenv("PICS_TO")) : -1;
	static uint32_t pic[224][288];
	int pics_n = 0, pics_exact = 0;
	while ((pics ? (pics_to < 0 || (long)((cyc - 64) / 811008) <= pics_to) : (mi < maxn && !bad)) && cyc < 4000000000ULL) {
		tick();
		static long npx = 0;
		if (pics && t->out_valid && t->out_y < 224 && t->out_x < 288) { pic[t->out_y][t->out_x] = t->red << 16 | t->green << 8 | t->blue; npx++; }
		if (pics && getenv("PICS_COUNT") && t->vcnt == 224 && lastv != 224) { printf("pixels %ld\n", npx); npx = 0; }
		if ((int)t->vcnt != lastv) {
			if (t->vcnt == 224) {
				frame++;
				long F = (long)((cyc - 64) / 811008) - 1;
				if (pics && F >= 0) {
					char pp[512]; snprintf(pp, sizeof pp, "%s/p%05ld.raw", pics, F);
					auto mp = load(pp);
					if (mp.size() == 288 * 224 * 4) {
						int diff = 0, fx = -1, fy = -1, ly = -1;
						for (int y = 0; y < 224; y++)
							for (int x = 0; x < 288; x++) {
								const uint8_t *q = &mp[(y * 288 + x) * 4];
								if ((pic[y][x] & 0xffffff) != (uint32_t)(q[0] | q[1] << 8 | q[2] << 16)) { if (!diff) { fx = x; fy = y; } diff++; ly = y; }
							}
						pics_n++; pics_exact += diff == 0;
						if (diff) printf("frame %ld: %d pixels differ (lines %d-%d; first at %d,%d)\n", F, diff, fy, ly, fx, fy);
						if (getenv("PICS_ALL") && !diff) printf("frame %ld: exact\n", F);
						fflush(stdout);
					}
					if (getenv("PICS_DUMP")) {
						snprintf(pp, sizeof pp, "%s/rtl%05ld.raw", getenv("PICS_DUMP"), F);
						FILE *df = fopen(pp, "wb"); if (df) { fwrite(pic, sizeof pic, 1, df); fclose(df); }
					}
				}
			}
			lastv = t->vcnt;
		}
		// a bus cycle: its address at AS, its data at DTACK
		// MCUREADS=file: the C68's DPRAM reads ("R addr data time"), to set against MAME's
		if (getenv("RAMWATCH")) { static int last = -1; int v = r->ns2_board__DOT__u_c68__DOT__ram[strtol(getenv("RAMWATCH"), 0, 16)];
			if (v != last) { printf("ram %s = %02x at %llu\n", getenv("RAMWATCH"), v, (unsigned long long)(cyc - 64)); last = v; } }
		// MCUFULL=file: every C68 cycle, in MAME's trace format ("R|W addr data time")
		if (getenv("MCUFULL")) { static FILE *mf = fopen(getenv("MCUFULL"), "w");
			if (t->mcu_c68 && t->mcu_cen && t->sub_run)
				fprintf(mf, "%c %04x %02x %llu\n", t->mcu_wr ? 'W' : 'R', t->mcu_addr, t->mcu_wr ? t->mcu_dout : t->mcu_din, (unsigned long long)(cyc - 64 + 1 - 24)); }
		if (getenv("MCUREADS")) { static FILE *mr = fopen(getenv("MCUREADS"), "w");
			if (t->mcu_c68 && t->mcu_cen && !t->mcu_wr && (t->mcu_addr & 0xf800) == 0x5000)
				fprintf(mr, "R %04x %02x %llu\n", t->mcu_addr, t->mcu_din, (unsigned long long)(cyc - 64 + 1 - 24)); }
		if (getenv("SNDDUMP")) { static unsigned la3 = 0x10000; static uint64_t c0 = 0; unsigned a = t->snd_addr;
			if (t->sound_run && !c0) { c0 = cyc; printf("sound_run at %llu\n", (unsigned long long)(cyc - 64)); }
			if (c0 && cyc < c0 + atol(getenv("SNDDUMP")) && a != la3) printf("snd %04x at %llu\n", a, (unsigned long long)(cyc - 64));
			la3 = a; }
		if (getenv("MCUDUMP")) { static unsigned la2 = 0x10000; static uint64_t c0 = 0; unsigned a = t->mcu_addr;
			if (t->sub_run && !c0) { c0 = cyc; printf("sub_run at %llu\n", (unsigned long long)(cyc - 64)); }
			if (c0 && cyc < c0 + atol(getenv("MCUDUMP")) && a != la2) printf("mcu %04x at %llu\n", a, (unsigned long long)(cyc - 64));
			la2 = a; }
		{ static unsigned la = 0; unsigned a = t->mcu_addr; if (a != la && (a == 0x1ff8 || a == 0x1fea || a == 0x1ffe || a == 0x1fff || a == 0x02a0 || a == 0x02a1) && getenv("DBGVEC")) printf("vec %04x cyc %llu vcnt %u frame %u mi %zu\n", a, (unsigned long long)cyc, (unsigned)t->vcnt, frame, mi); la = a; }
		if (cpu == "c140") {
			// C140LOG=file: the 6809's C140 writes as the board makes them, in the
			// harness's trace format (sim/rtl/ns2_c140)
			static FILE *clog = getenv("C140LOG") ? fopen(getenv("C140LOG"), "w") : nullptr;
			if (clog && t->snd_wr && ((t->snd_addr & 0xf000) == 0x5000 || (t->snd_addr & 0xf000) == 0x6000))
				fprintf(clog, "W %06x %04x 00ff %u %llu\n", t->snd_addr, t->snd_dout, frame, (unsigned long long)(cyc - 64));
			if (t->c140_sample && mi < mame.size()) {
				const Acc &m = mame[mi];
				int16_t ml = (int16_t)(m.data >> 16), mr = (int16_t)(m.data & 0xffff), rl = (int16_t)t->c140_raw_l, rr = (int16_t)t->c140_raw_r;
				if (ml != rl || mr != rr) {
					printf("sample %zu (%.3f s, rtl frame %u): rtl %d %d, mame %d %d\n", mi, mi / 21333.0, frame, rl, rr, ml, mr);
					printf("  mame:"); for (size_t k = mi > 4 ? mi - 4 : 0; k < mi + 4 && k < mame.size(); k++) printf(" %d/%d", (int16_t)(mame[k].data >> 16), (int16_t)(mame[k].data & 0xffff)); printf("\n");
					bad = !getenv("NOSTOP");
				}
				mi++;
			}
			continue;
		}
		if (wonly) {
			unsigned a = snd ? t->snd_addr : t->mcu_addr, d = snd ? t->snd_dout : t->mcu_dout;
			if ((snd ? t->snd_wr : t->mcu_wr) && (!dponly || in_dp(a)) && mi < mame.size()) {
				const Acc &m = mame[mi];
				// WTIMES=n: the writes where the RTL's offset from MAME's time changes by more than n
				static const double wt = getenv("WTIMES") ? atof(getenv("WTIMES")) : -1; static double lo = 1e30;
				if (wt >= 0 && m.t >= 0) {
					double off = (double)(cyc - 64) - m.t;
					if (fabs(off - lo) > wt) printf("write %zu %04x:%02x (mame frame %d): offset %+.0f\n", mi, a, d, m.frame, off);
					lo = off;
				}
				if (m.rw != 'W' || m.addr != a || (m.data & 0xff) != d) {
					printf("write %zu (rtl frame %u, mame frame %d): rtl W %04x %02x, mame %c %04x %02x\n", mi, frame, m.frame, a, d, m.rw, m.addr, m.data);
					printf("  mame before:"); for (size_t k = mi > 8 ? mi - 8 : 0; k < mi; k++) printf(" %04x:%02x", mame[k].addr, mame[k].data); printf("\n");
					printf("  mame after: "); for (size_t k = mi; k < mi + 8 && k < mame.size(); k++) printf(" %04x:%02x", mame[k].addr, mame[k].data); printf("\n");
					bad = !getenv("NOSTOP");
				}
				mi++;
			}
			continue;
		}
		// C116WATCH=1: the C116's registers 0-3 as they change
		if (getenv("C116WATCH")) { static uint16_t last[4] = {1, 1, 1, 1};
			for (int k = 0; k < 4; k++) { uint16_t v = r->ns2_board__DOT__u_video__DOT__c116[k];
				if (v != last[k]) { printf("c116[%d] = %03x at frame %.3f\n", k, v, (cyc - 64) / 811008.0); last[k] = v; } } }
		// WLOG=file: the master's writes to the C116 registers (0x44xxxx, offset & 0x1800 == 0x1800) at their clocks
		if (getenv("WLOG")) { static FILE *wl = fopen(getenv("WLOG"), "w"); static bool asd = false;
			bool asn = t->m_as;
			unsigned wa = (unsigned)t->m_addr << 1;
			if (asn && !asd && !t->m_rnw && (wa >> 16) == 0x44 && (((wa - 0x440000) >> 1) & 0x1800) == 0x1800)
				fprintf(wl, "%llu %06x %04x\n", (unsigned long long)(cyc - 64), wa, t->m_wdata);
			asd = asn; }
		// MDUMP_S=file: the slave's accesses, as MDUMP
		{
			static FILE *sdm = getenv("MDUMP_S") ? fopen(getenv("MDUMP_S"), "w") : nullptr;
			static bool s_as_d = false, s_pend = false; static char s_rw; static unsigned s_a, s_d, s_m;
			if (sdm) {
				if (t->s_as && !s_as_d) { s_pend = true; s_rw = t->s_rnw ? 'R' : 'W'; s_a = t->s_addr << 1; s_d = t->s_wdata;
				                          s_m = (t->s_ds & 2 ? 0xff00 : 0) | (t->s_ds & 1 ? 0xff : 0); }
				s_as_d = t->s_as;
				if (s_pend && t->s_dtack) { s_pend = false; fprintf(sdm, "%c %06x %04x %04x\n", s_rw, s_a, s_rw == 'R' ? (unsigned)t->s_rdata : s_d, s_m); }
			}
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
			// STRACE=frame,n: the 6809's address changes and sound_run for n clocks from a frame
			static long st_f = getenv("STRACE") ? atol(getenv("STRACE")) : -1, st_n = getenv("STRACE") && strchr(getenv("STRACE"), ',') ? atol(strchr(getenv("STRACE"), ',') + 1) : 0;
			static unsigned st_a = 0x10000; static int st_r = -1;
			if (st_f >= 0 && (long)((cyc - 64) / 811008) >= st_f && st_n > 0) {
				st_n--;
				if (t->snd_addr != st_a || (int)t->sound_run != st_r) { printf("snd %llu %04x run %d\n", (unsigned long long)(cyc - 64), t->snd_addr, t->sound_run); st_a = t->snd_addr; st_r = t->sound_run; }
			}
			static FILE *sd = getenv("SDUMP") ? fopen(getenv("SDUMP"), "w") : nullptr;
			if (sd && t->snd_wr && (t->snd_addr & 0xf000) == 0x7000) fprintf(sd, "%llu %04x %02x\n", (unsigned long long)(cyc - 64), t->snd_addr, t->snd_dout);
			if (ud && t->mcu_wr && (t->mcu_addr & 0xf800) == 0x5000) fprintf(ud, "%llu %04x %02x\n", (unsigned long long)(cyc - 64), t->mcu_addr, t->mcu_dout);
		}
		bool as = slave ? t->s_as : t->m_as, rnw = slave ? t->s_rnw : t->m_rnw;
		unsigned ds = slave ? t->s_ds : t->m_ds;
		if (as && !as_d) {
			pend = {rnw ? 'R' : 'W', (unsigned)(slave ? t->s_addr : t->m_addr) << 1, rnw ? 0u : (slave ? t->s_wdata : t->m_wdata),
			        (unsigned)((ds & 2 ? 0xff00 : 0) | (ds & 1 ? 0x00ff : 0)), (int)frame};
			have_pend = true; pend_cyc = cyc;
		}
		as_d = as;
		if (have_pend && (slave ? t->s_dtack : t->m_dtack) && mi < mame.size()) {
			have_pend = false;
			if (pend.rw == 'R') pend.data = slave ? t->s_rdata : t->m_rdata;
			// DELTA=start: the accesses after which the RTL's gap to the next differs from MAME's
			static const size_t dstart = getenv("DELTA") ? atol(getenv("DELTA")) : 0; static uint64_t lastc = 0; static int shown = 0;
			if (dstart && mi > dstart && mame[mi].t >= 0 && shown < (getenv("DSHOW") ? atoi(getenv("DSHOW")) : 40)) {
				// reads only: a write is stamped when its data strobe falls, a state after AS
				static double lastoff = 0; static size_t lastr = 0;
				if (pend.rw == 'R') {
					double off = (double)pend_cyc - mame[mi].t;
					if (lastr && off != lastoff) {
						shown++; printf("drift %+.0f at %zu:", off - lastoff, mi);
						for (size_t k = lastr; k <= mi; k++) printf(" %c%06x", mame[k].rw, mame[k].addr);
						printf("\n");
					}
					lastoff = off; lastr = mi;
				}
			}
			lastc = pend_cyc;
			if (times && mi % times == 0 && mame[mi].t >= 0)
				printf("access %zu: rtl clock %llu, mame %.0f (rtl - mame %+.0f)\n", mi, (unsigned long long)(cyc - 64), mame[mi].t, (double)(cyc - 64) - mame[mi].t);
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
	if (pics) printf("pictures: %d of %d exact\n", pics_exact, pics_n);
	printf("%zu of %zu %s accesses matched (%llu clocks, frame %u)%s\n", bad ? mi - 1 : mi, maxn, cpu.c_str(),
	       (unsigned long long)cyc, frame, (!bad && mi >= maxn) ? ": ALL MATCH" : "");
	delete t;
	return bad ? 1 : 0;
}
