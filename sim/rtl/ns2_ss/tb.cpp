// M5's savestate gate (docs/savestates.md), after Arcade-GingaNin_MiSTer's:
//   make && KEY="$(tools/ns2_keys.py --tb SET)" BOARD=n [PORTS=file] ./obj_dir/Vss_top SET [T [K]]
// The board from power-on (sim/rtl/roms/SET, as sim/rtl/ns2_frames), the
// savestate engine on a DDR model. Save slot 0 in frame T (default 400);
// K frames (default 60) after it resumes, save slot 1; then load slot 0 and,
// K frames after that resumes, save slot 2. Slots 1 and 2 must be equal word
// for word (the YM2151's shadow included), and each of the K frames after the
// load's resume must equal its frame after the save's: the picture, both
// 68000s' accesses, the 6809's and the MCU's writes (each hashed per frame).
// The YM2151's sound is not compared (its operators restart from their
// registers). SS_DBG=1 prints each frame's hashes.
#include "Vss_top.h"
#include "Vss_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

#define B(x) r->ss_top__DOT__u_board__DOT__##x

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
struct Hash { uint64_t h = 1469598103934665603ULL; void add(uint64_t v) { h = (h ^ v) * 1099511628211ULL; } };
enum { H_PIC, H_M, H_S, H_SND, H_MCU, H_N };
static const char *hname[H_N] = {"picture", "master", "slave", "6809", "MCU"};

static const char *region(unsigned a) {
	if (a < 0x08000) return "master work RAM"; if (a < 0x10000) return "slave work RAM";
	if (a < 0x18000) return "C123 RAM"; if (a < 0x20000) return "C116"; if (a < 0x30000) return "ROZ RAM";
	if (a < 0x38000) return "C169 RAM"; if (a < 0x50000) return "C355 RAM"; if (a < 0x52000) return "sprite RAM";
	if (a < 0x54000) return "C139 RAM"; if (a < 0x56000) return "EEPROM"; if (a < 0x58000) return "DPRAM";
	if (a < 0x5a000) return "sound RAM"; if (a < 0x5a200) return "C140 registers"; if (a < 0x5a300) return "YM shadow";
	if (a < 0x5a380) return "video registers"; if (a < 0x5a400) return "registers"; if (a < 0x5a600) return "C65 RAM";
	if (a < 0x5a800) return "C68 RAM"; return "C140 voices";
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 2) { fprintf(stderr, "usage: SET [T [K]]\n"); return 1; }
	std::string set = argv[1], rd = std::string("../roms/") + set + "/";
	const int SS_T = argc > 2 ? atoi(argv[2]) : 400, SS_K = argc > 3 ? atoi(argv[3]) : 60;
	auto mrom = load(rd + "maincpu.bin"), srom = load(rd + "slave.bin"), drom = load(rd + "data.bin"),
	     arom = load(rd + "audio.bin"), irom = load(rd + "mcu_int.bin"), erom = load(rd + "mcu_ext.bin"),
	     tiles = load(rd + "tiles.bin"), tmask = load(rd + "tmask.bin"), roz = load(rd + "roz.bin"),
	     spr = load(rd + "sprite.bin"), nv = load(rd + "nvram.bin"), vro = load(rd + "c140.bin"),
	     c169 = load(rd + "c169.bin"), c169m = load(rd + "c169mask.bin"), c355 = load(rd + "c355.bin"), clut = load(rd + "clut.bin");
	if (c169.empty()) c169.assign(8, 0);
	if (c169m.empty()) c169m.assign(8, 0);
	if (spr.empty()) spr = c355;
	if (spr.empty()) spr.assign(8, 0);
	if (mrom.empty() || srom.empty() || irom.empty() || erom.empty()) { fprintf(stderr, "ROMs missing (tools/ns2_romdump.py)\n"); return 1; }
	if (roz.empty()) roz.assign(8, 0xff);
	std::map<std::string, unsigned> ports;
	{
		// the inputs: PORTS, or the set's board trace's (sim/oracle/traces/SET_board)
		std::string pf = getenv("PORTS") ? getenv("PORTS") : "../../oracle/traces/" + set + "_board/ports.txt";
		FILE *f = fopen(pf.c_str(), "r");
		if (!f) fprintf(stderr, "no %s: the default inputs\n", pf.c_str());
		char n[64]; unsigned v;
		while (f && fscanf(f, "%63s %x", n, &v) == 2) ports[n] = v;
		if (f) fclose(f);
	}

	Vss_top *t = new Vss_top;
	auto *r = t->rootp;
	for (size_t i = 0; i < mrom.size() / 2; i++) B(g_arrays__DOT__mrom)[i] = mrom[2 * i] << 8 | mrom[2 * i + 1];
	for (size_t i = 0; i < srom.size() / 2; i++) B(g_arrays__DOT__srom)[i] = srom[2 * i] << 8 | srom[2 * i + 1];
	for (size_t i = 0; i < drom.size() / 2 && i < (1u << 20); i++) B(g_arrays__DOT__drom)[i] = drom[2 * i] << 8 | drom[2 * i + 1];
	for (size_t i = 0; i < (1u << 18); i++) B(g_arrays__DOT__arom)[i] = arom.empty() ? 0xff : arom[i % arom.size()];
	for (size_t i = 0; i < vro.size() / 2 && i < (1u << 20); i++) B(g_arrays__DOT__vrom)[i] = vro[2 * i] << 8 | vro[2 * i + 1];
	for (size_t i = 0; i < irom.size() && i < 32768; i++) B(g_arrays__DOT__irom)[i] = irom[i];
	t->mcu_c68 = irom.size() == 32768;
	for (size_t i = 0; i < 32768; i++) B(g_arrays__DOT__erom)[i] = erom[i];
	for (size_t i = 0; i < 8192; i++) B(u_main__DOT__u_master__DOT__eep)[i] = nv.size() == 8192 ? nv[i] : 0xff;
	t->board = getenv("BOARD") ? atoi(getenv("BOARD")) : 0;
	t->tile_fl2 = getenv("TILE_FL2") != nullptr; t->spr_fl = getenv("SPR_FL") != nullptr;
	for (size_t i = 0; i < 256 && i < clut.size(); i++) B(u_video__DOT__clut)[i] = clut[i];
	auto port = [&](const char *n, unsigned d) { return ports.count(n) ? ports[n] : d; };
	t->mcub = port(":MCUB", 0xff); t->mcuc = port(":MCUC", 0xff); t->mcuh = port(":MCUH", 0xff); t->dsw = port(":DSW", 0xff);
	t->dials = port(":MCUDI0", 0xff) | port(":MCUDI1", 0xff) << 8 | port(":MCUDI2", 0xff) << 16 | port(":MCUDI3", 0xff) << 24;
	t->analog = 0;
	for (int i = 0; i < 8; i++) { char n[8]; snprintf(n, 8, ":AN%d", i); t->analog |= (uint64_t)port(n, 0xff) << (8 * i); }
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
	// the boot's Start press (as sim/rtl/ns2_frames), long before the save
	std::string start_port; unsigned start_mask = 0, boot_start = 300;
	for (auto &p : ports) if (p.first.rfind("start", 0) == 0) { start_port = p.first.substr(5); start_mask = p.second; }
	if (ports.count("boot_start")) boot_start = ports["boot_start"];
	const unsigned mcub0 = t->mcub, mcuc0 = t->mcuc, mcuh0 = t->mcuh;
	auto inputs = [&]() {
		uint64_t f = (cyc > 64 ? cyc - 64 : 0) / 811008;
		unsigned clr = (f > boot_start && f <= boot_start + 6) ? start_mask : 0;
		t->mcub = start_port == ":MCUB" ? mcub0 & ~clr : mcub0;
		t->mcuc = start_port == ":MCUC" ? mcuc0 & ~clr : mcuc0;
		t->mcuh = start_port == ":MCUH" ? mcuh0 & ~clr : mcuh0;
	};
	if (SS_T <= (int)boot_start + 10) fprintf(stderr, "warning: T is before the boot's Start press ends (frame %u)\n", boot_start + 7);
	Stream st_tile{&tiles, 8}, st_mask{&tmask, 1}, st_roz{&roz, 8}, st_spr{&spr, 8}, st_c169{&c169, 8}, st_c169m{&c169m, 8};

	// the DDR model: 4 slots of 0x20000 words; a read answers 8 clocks later
	std::vector<uint64_t> ddr(4 * 0x20000, 0);
	std::deque<std::pair<uint64_t, uint32_t>> ddrq;
	Hash cur[H_N];
	// SS_TRACE=n: each 68000's first n accesses after each release (the
	// board leaves its freeze), with their clock from it; the first difference
	struct TA { int who; uint32_t a; uint32_t d; uint64_t c; };
	const size_t trace_n = getenv("SS_TRACE") ? atol(getenv("SS_TRACE")) : 0;
	std::vector<TA> tr[2];
	int tr_run = -1; uint64_t rel_cyc = 0, c_req = 0;
	int step = 0;
	bool m_as_d = false, s_as_d = false, m_dt_d = false, s_dt_d = false;
	auto tick = [&]() {
		uint8_t a, v; uint64_t d;
		st_tile.serve(t->tile_req, t->tile_addr, a, v, d); t->tile_ack = a; t->tile_valid = v; if (v) t->tile_data = d;
		st_mask.serve(t->tmask_req, t->tmask_addr, a, v, d); t->tmask_ack = a; t->tmask_valid = v; if (v) t->tmask_data = d;
		st_roz.serve(t->roz_req, t->roz_addr, a, v, d); t->roz_ack = a; t->roz_valid = v; if (v) t->roz_data = d;
		st_spr.serve(t->spr_req, t->spr_addr, a, v, d); t->spr_ack = a; t->spr_valid = v; if (v) t->spr_data = d;
		st_c169.serve(t->c169_req, t->c169_addr, a, v, d); t->c169_ack = a; t->c169_valid = v; if (v) t->c169_data = d;
		st_c169m.serve(t->c169m_req, t->c169m_addr >> 3, a, v, d); t->c169m_ack = a; t->c169m_valid = v; if (v) t->c169m_data = d;
		if (t->ddr_we) ddr[t->ddr_addr % ddr.size()] = t->ddr_din;
		if (t->ddr_rd) ddrq.push_back({cyc + 8, (uint32_t)(t->ddr_addr % ddr.size())});
		t->ddr_dout_ready = 0;
		if (!ddrq.empty() && ddrq.front().first <= cyc) { t->ddr_dout = ddr[ddrq.front().second]; t->ddr_dout_ready = 1; ddrq.pop_front(); }
		if ((cyc & 1023) == 0) inputs();
		t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
		// the buses: an access at its DTACK (reads: the data the CPU takes)
		if (t->m_dtack && !m_dt_d) cur[H_M].add((uint64_t)t->m_addr << 34 | (uint64_t)t->m_rnw << 33 | (t->m_rnw ? t->m_rdata : t->m_wdata));
		if (t->s_dtack && !s_dt_d) cur[H_S].add((uint64_t)t->s_addr << 34 | (uint64_t)t->s_rnw << 33 | (t->s_rnw ? t->s_rdata : t->s_wdata));
		// the engine's phases: freeze, the board frozen, the transfer, the
		// replay, the release (the traces count from it)
		{ static uint8_t pv = 0; uint8_t v = t->dbg_freeze | t->ss_frz << 1 | t->dbg_active << 2 | t->dbg_replay << 3 | t->dbg_resume << 4;
		  if (v != pv && getenv("SS_PHASES")) printf("    phases %c%c%c%c%c at %.3f ms (frame line %u)\n", v & 1 ? 'F' : '-', v & 2 ? 'Z' : '-',
		      v & 4 ? 'A' : '-', v & 8 ? 'R' : '-', v & 16 ? 'U' : '-', (cyc - c_req) / 49152.0, (unsigned)t->vcnt);
		  if ((v & 16) && !(pv & 16)) { rel_cyc = cyc; tr_run = step == 1 ? 0 : step == 5 ? 1 : -1; }
		  pv = v; }
		if (tr_run >= 0 && tr[tr_run].size() < trace_n) {
			if (t->m_dtack && !m_dt_d) tr[tr_run].push_back({0, (uint32_t)t->m_addr << 1 | t->m_rnw << 31, t->m_rnw ? t->m_rdata : t->m_wdata, cyc - rel_cyc});
			if (t->s_dtack && !s_dt_d) tr[tr_run].push_back({1, (uint32_t)t->s_addr << 1 | t->s_rnw << 31, t->s_rnw ? t->s_rdata : t->s_wdata, cyc - rel_cyc});
		}
		m_dt_d = t->m_dtack; s_dt_d = t->s_dtack;
		if (t->snd_wr) cur[H_SND].add((uint64_t)t->snd_addr << 8 | t->snd_dout);
		if (t->mcu_wr) cur[H_MCU].add((uint64_t)t->mcu_addr << 8 | t->mcu_dout);
		if (t->out_valid && t->out_y < 224 && t->out_x < 288) cur[H_PIC].add((uint64_t)t->out_y << 40 | (uint64_t)t->out_x << 24 | t->red << 16 | t->green << 8 | t->blue);
	};
	t->reset = 1; for (int i = 0; i < 64; i++) tick(); t->reset = 0;

	// 0 before, 1 save 0, 2 its run, 3 save 1, 4 wait, 5 load 0, 6 its run, 7 save 2, 8 done
	// (a request and its completion each advance the step)
	int frame = 0, mark = -1, lastv = -1;
	std::vector<std::vector<uint64_t>> ha(H_N), hb(H_N);
	while (step < 8 && cyc < 64ULL + 811008ULL * (SS_T + 3 * SS_K + 60)) {
		tick();
		if (t->ss_done_ok || t->ss_done_fail) {
			printf("step %d: %s (fail code %d) in frame %d, %.2f ms\n", step, t->ss_done_ok ? "ok" : "FAILED",
			       t->ss_fail_code, frame, (cyc - c_req) / 49152.0);
			fflush(stdout);
			if (t->ss_done_fail) { printf("SS gate: FAIL\n"); return 1; }
			step++; mark = frame;
			for (auto &h : cur) h = Hash();

		}
		if ((int)t->vcnt != lastv && t->vcnt == 224) {
			// a frame ends: its hashes (in the runs after each resume)
			if (step == 2 || step == 6) for (int k = 0; k < H_N; k++) (step == 2 ? ha : hb)[k].push_back(cur[k].h);
			if (getenv("SS_DBG") && (step == 2 || step == 6))
				printf("  step %d frame +%d: %016llx %016llx %016llx %016llx %016llx\n", step, frame - mark,
				       (unsigned long long)cur[0].h, (unsigned long long)cur[1].h, (unsigned long long)cur[2].h,
				       (unsigned long long)cur[3].h, (unsigned long long)cur[4].h);
			for (auto &h : cur) h = Hash();
			frame++;
			auto req = [&](bool ld, int sl) { if (ld) t->load_req = 1; else t->save_req = 1; t->slot = sl; c_req = cyc; step++; };
			if (step == 0 && frame == SS_T) req(false, 0);
			else if (step == 2 && frame == mark + SS_K) req(false, 1);
			else if (step == 4 && frame == mark + 5) req(true, 0);
			else if (step == 6 && frame == mark + SS_K) req(false, 2);
		}
		lastv = t->vcnt;
		if (t->save_req || t->load_req) { tick(); t->save_req = 0; t->load_req = 0; }
	}
	if (step < 8) { printf("SS gate: FAIL (stuck at step %d)\n", step); return 1; }
	if (trace_n) {
		size_t n = std::min(tr[0].size(), tr[1].size()), i = 0;
		while (i < n && tr[0][i].who == tr[1][i].who && tr[0][i].a == tr[1][i].a && tr[0][i].d == tr[1][i].d && tr[0][i].c == tr[1][i].c) i++;
		printf("  traces: %zu accesses equal (of %zu, %zu)\n", i, tr[0].size(), tr[1].size());
		for (size_t j = i > 3 ? i - 3 : 0; j < i + 6 && j < n; j++)
			printf("    %zu: %s %c %06x %04x +%llu | %s %c %06x %04x +%llu\n", j,
			       tr[0][j].who ? "slave " : "master", tr[0][j].a >> 31 ? 'R' : 'W', tr[0][j].a & 0xffffff, tr[0][j].d, (unsigned long long)tr[0][j].c,
			       tr[1][j].who ? "slave " : "master", tr[1][j].a >> 31 ? 'R' : 'W', tr[1][j].a & 0xffffff, tr[1][j].d, (unsigned long long)tr[1][j].c);
	}
	// the images
	const unsigned words = 0x5ac00;
	auto w16 = [&](int sl, unsigned i) { return (uint16_t)(ddr[sl * 0x20000 + 1 + i / 4] >> (16 * (i % 4))); };
	int total = 0; std::map<std::string, int> per;
	for (unsigned i = 0; i < words; i++)
		if (w16(1, i) != w16(2, i)) {
			if (total < 24) printf("  word %05x (%s): slot 1 %04x, slot 2 %04x\n", i, region(i), w16(1, i), w16(2, i));
			total++; per[region(i)]++;
		}
	for (auto &p : per) printf("  %s: %d words differ\n", p.first.c_str(), p.second);
	// the frames
	int bad = 0;
	size_t n = std::min(ha[0].size(), hb[0].size());
	for (int k = 0; k < H_N; k++) {
		int d = 0, first = -1;
		for (size_t i = 0; i < n; i++) if (ha[k][i] != hb[k][i]) { if (first < 0) first = i; d++; }
		printf("  %s: %d of %zu frames differ%s", hname[k], d, n, d ? "" : "\n");
		if (d) printf(" (the first: +%d)\n", first);
		bad += d;
	}
	printf("SS gate: slots 1 and 2 differ in %d words; %d frame hashes differ; %s\n", total, bad,
	       total == 0 && bad == 0 && n > 0 ? "PASS" : "FAIL");
	return total == 0 && bad == 0 && n > 0 ? 0 : 1;
}
