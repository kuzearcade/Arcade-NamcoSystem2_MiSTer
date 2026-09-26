// The C68 (rtl/ns2_c68.sv: rtl/ns2_m740.sv and the M37450's peripherals)
// alone against MAME's own trace of it (NS2-9): every bus cycle, in order.
//   ./obj_dir/Vns2_c68 SET TRACE_DIR [cycles]
// TRACE_DIR/mcu_bus.txt: sim/oracle/ns2_bustrace.lua with MP_CPU=mcu
// MP_TIME=1 (MAME's taps see every M37450 cycle, each stamped at its start),
// and ports.txt. The edge that ends a clock stands for MAME's time at the
// clock's end. The MCU leaves reset at MAME's first access; line 200 comes
// at MAME's times (time 0 is vpos 224: line 200 is 240 lines on); the DPRAM
// reads return MAME's values (the 68000s are not here). Every other read
// must return MAME's value by itself.
#include "Vns2_c68.h"
#include "verilated.h"
#include "Vns2_c68___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <map>
#include <string>
#include <vector>

struct Acc { char rw; unsigned addr, data; double t; };

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET TRACE_DIR [cycles]\n"); return 1; }
	std::string td = argv[2];
	std::vector<uint8_t> rom;
	{
		FILE *f = fopen((std::string("../roms/") + argv[1] + "/mcu_int.bin").c_str(), "rb");
		if (!f) { fprintf(stderr, "no mcu_int.bin (tools/ns2_romdump.py)\n"); return 1; }
		rom.resize(32768); if (fread(rom.data(), 1, 32768, f) != 32768) { fprintf(stderr, "mcu_int.bin is not c68.bin\n"); return 1; } fclose(f);
	}
	std::vector<Acc> m;
	{
		FILE *f = fopen((td + "/mcu_bus.txt").c_str(), "r");
		char line[128], rw; unsigned a, d, mk; int fr; double tm;
		while (f && fgets(line, sizeof line, f))
			if (sscanf(line, " %c %x %x %x %d %lf", &rw, &a, &d, &mk, &fr, &tm) == 6) m.push_back({rw, a, d & 0xff, tm});
		if (f) fclose(f);
		if (m.empty()) { fprintf(stderr, "no mcu_bus.txt with times\n"); return 1; }
	}
	std::map<std::string, unsigned> ports;
	{
		FILE *f = fopen((td + "/ports.txt").c_str(), "r");
		char n[64]; unsigned v;
		while (f && fscanf(f, "%63s %x", n, &v) == 2) ports[n] = v;
		if (f) fclose(f);
	}
	auto port = [&](const char *n, unsigned d) { return ports.count(n) ? ports[n] : d; };
	// line 200: MAME's time, but where MAME entered the VBL interrupt within
	// two cycles of it, that fetch's end (MAME's scheduler lets the MCU run
	// up to a cycle past an event, so its interrupts land a cycle apart;
	// NS2-9). An entry: the fetch, its PC read again, three pushes, the
	// vector 0xfff8.
	std::map<uint64_t, uint64_t> ev200;               // frame -> the event's time
	for (size_t k = 0; k + 5 < m.size(); k++)
		if (m[k + 5].rw == 'R' && m[k + 5].addr == 0xfff8 && m[k + 1].addr == m[k].addr && m[k + 2].rw == 'W' && m[k + 4].rw == 'W') {
			uint64_t end = (uint64_t)m[k].t + 24, fr = (end - 240 * 3072 + 811008 / 2) / 811008;
			int64_t d = (int64_t)end - (int64_t)(fr * 811008 + 240 * 3072);
			if (d >= -48 && d <= 48) ev200[fr] = end;
		}
	if (getenv("EVDUMP")) for (auto &e : ev200) printf("ev200 frame %llu at %llu (nominal %+lld)\n", (unsigned long long)e.first, (unsigned long long)e.second, (long long)e.second - (long long)(e.first * 811008 + 240 * 3072));
	auto is_ev200 = [&](uint64_t tm) {
		uint64_t fr = tm < 240 * 3072 ? 0 : (tm - 240 * 3072 + 811008 / 2) / 811008;
		auto it = ev200.find(fr);
		return it != ev200.end() ? tm == it->second : tm == fr * 811008 + 240 * 3072;
	};
	size_t maxn = argc > 3 ? atol(argv[3]) : m.size();
	if (maxn > m.size()) maxn = m.size();

	Vns2_c68 *t = new Vns2_c68;
	const uint64_t t0 = (uint64_t)m[0].t;           // MAME's release: its first access starts here
	uint64_t cyc = t0 > 64 ? t0 - 64 : 0;           // MAME's time, in clocks
	t->mcub = port(":MCUB", 0xff); t->mcuc = port(":MCUC", 0xff); t->mcuh = port(":MCUH", 0xff); t->dsw = port(":DSW", 0xff);
	t->dials = port(":MCUDI0", 0xff) | port(":MCUDI1", 0xff) << 8 | port(":MCUDI2", 0xff) << 16 | port(":MCUDI3", 0xff) << 24;
	t->analog = 0;
	for (int i = 0; i < 8; i++) { char n[8]; snprintf(n, 8, ":AN%d", i); t->analog |= (uint64_t)port(n, 0xff) << (8 * i); }
	std::string start_port; unsigned start_mask = 0, boot_start = 300;
	for (auto &p : ports) if (p.first.rfind("start", 0) == 0) { start_port = p.first.substr(5); start_mask = p.second; }
	if (ports.count("boot_start")) boot_start = ports["boot_start"];
	const unsigned mcub0 = t->mcub, mcuc0 = t->mcuc, mcuh0 = t->mcuh;

	size_t mi = 0; int bad = 0; double lastoff = 1e30; int shown = 0;
	const double wt = getenv("WTIMES") ? atof(getenv("WTIMES")) : 1e30;
	while (mi < maxn && !bad) {
		// the inputs: the boot script's Start press (MAME's frames boot_start+1 .. +6)
		uint64_t f = cyc / 811008;
		unsigned clr = (f > boot_start && f <= boot_start + 6) ? start_mask : 0;
		t->mcub = start_port == ":MCUB" ? mcub0 & ~clr : mcub0;
		t->mcuc = start_port == ":MCUC" ? mcuc0 & ~clr : mcuc0;
		t->mcuh = start_port == ":MCUH" ? mcuh0 & ~clr : mcuh0;
		t->reset = cyc < t0;
		// the edge at the end of clock c stands for MAME's time c + 1
		t->irq_line200 = is_ev200(cyc + 1);
		// a DPRAM read returns MAME's value; the ROM answers at once (the
		// address is stable for the cycle's 24 clocks)
		t->dp_din = m[mi].data;
		t->eval();
		t->rom_data = rom[t->rom_addr & 0x7fff];
		t->eval();
		// cen: the next edge completes the cycle; compare it before the edge
		bool done = t->dbg_cen && !t->reset;
		if (done && getenv("PEEK") && mi >= (size_t)atol(getenv("PEEK")) && mi < (size_t)atol(getenv("PEEK")) + 60) {
			auto *r = t->rootp;
			printf("  %zu: addr %04x wr %d adc_cnt %d adctrl %02x req1 %02x req2 %02x ctl1 %02x ctl2 %02x P %02x\n", mi, t->dbg_addr, t->dbg_wr,
			       r->ns2_c68__DOT__adc_cnt, r->ns2_c68__DOT__adctrl, r->ns2_c68__DOT__req1, r->ns2_c68__DOT__req2,
			       r->ns2_c68__DOT__ctl1, r->ns2_c68__DOT__ctl2, r->ns2_c68__DOT__u_cpu__DOT__P);
		}
		if (done) {
			const Acc &a = m[mi];
			unsigned addr = t->dbg_addr, data = t->dbg_wr ? t->dbg_dout : t->dbg_din;
			char rw = t->dbg_wr ? 'W' : 'R';
			// the cycle started 24 clocks before the edge that completes it
			double off = (double)(cyc + 1 - 24) - a.t;
			if (off != lastoff && shown < 40 && fabs(off - lastoff) > wt) { shown++; printf("cycle %zu %c %04x: offset %+.0f\n", mi, rw, addr, off); }
			lastoff = off;
			if (rw != a.rw || addr != a.addr || data != a.data) {
				printf("cycle %zu (%.0f): rtl %c %04x %02x, mame %c %04x %02x\n", mi, a.t, rw, addr, data, a.rw, a.addr, a.data);
				printf("  mame before:"); for (size_t k = mi > 10 ? mi - 10 : 0; k < mi; k++) printf(" %c%04x:%02x", m[k].rw, m[k].addr, m[k].data); printf("\n");
				printf("  mame after: "); for (size_t k = mi; k < mi + 6 && k < m.size(); k++) printf(" %c%04x:%02x", m[k].rw, m[k].addr, m[k].data); printf("\n");
				bad = 1;
			}
		}
		t->clk = 1; t->eval(); t->clk = 0; t->eval();
		if (done) mi++;
		cyc++;
	}
	printf("%zu of %zu cycles matched%s\n", bad ? mi - 1 : mi, maxn, bad ? "" : ": ALL MATCH");
	delete t;
	return bad;
}
