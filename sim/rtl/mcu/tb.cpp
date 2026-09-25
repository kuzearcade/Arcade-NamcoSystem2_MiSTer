// M2 (docs/PLAN.md D2): the C65's HD63705 (rtl/ns2_hd63705.v) against
// MAME's own MCU traces (sim/oracle/ns2_mcutrace.lua), on its own:
//   ./obj_dir/Vns2_hd63705 SET TRACE_DIR [max_accesses]
// ROMs (sim/rtl/roms/SET: mcu_int.bin, mcu_ext.bin) and RAM are modelled
// here; a read of the C65's I/O (ports 0x00-0x3f, DIPs 0x2000, dials
// 0x3000-3, DPRAM 0x5000-57ff, watchdog 0x6000) returns, in order, the
// values MAME read at that address. At each instruction boundary, when
// MAME's next accesses are an interrupt's five pushes and vector read, the
// harness raises that interrupt (IRQ1 at 0x1ff8, the A/D at 0x1fea). Every
// access (the core's operand/opcode loads and its writes) is compared with
// MAME's stream; the first difference stops the run.
#include "Vns2_hd63705.h"
#include "Vns2_hd63705___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <string>
#include <vector>

struct Acc { char rw; unsigned addr, data; };

static std::vector<uint8_t> load(const std::string &p) {
	std::vector<uint8_t> v; FILE *f = fopen(p.c_str(), "rb"); if (!f) return v;
	fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
	if (fread(v.data(), 1, v.size(), f) != v.size()) v.clear(); fclose(f); return v;
}
static bool io(unsigned a) {
	return (a < 0x40 && (a == 1 || a == 2 || a == 3 || a == 7 || a == 0x10 || a == 0x11 || a == 0)) ||
	       a == 0x2000 || (a >= 0x3000 && a <= 0x3003) || (a >= 0x5000 && a <= 0x57ff) || (a >= 0x6000 && a <= 0x6fff);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET TRACE_DIR [max]\n"); return 1; }
	std::string rd = std::string("../roms/") + argv[1] + "/";
	auto irom = load(rd + "mcu_int.bin"), erom = load(rd + "mcu_ext.bin");
	if (irom.size() != 8192 || erom.size() != 32768) { fprintf(stderr, "ROMs missing (tools/ns2_romdump.py)\n"); return 1; }
	std::vector<Acc> mame;
	{
		FILE *f = fopen((std::string(argv[2]) + "/mcu_bus.txt").c_str(), "r");
		char rw; unsigned a, d;
		while (f && fscanf(f, " %c %x %x", &rw, &a, &d) == 3) mame.push_back({rw, a, d});
		if (f) fclose(f);
	}
	size_t maxn = argc > 3 ? atol(argv[3]) : mame.size();
	// the values MAME read from each I/O address, in order
	std::map<unsigned, std::deque<unsigned>> ioread;
	for (auto &m : mame) if (m.rw == 'R' && io(m.addr)) ioread[m.addr].push_back(m.data);

	static uint8_t ram[0x200];
	Vns2_hd63705 *t = new Vns2_hd63705;
	auto *r = t->rootp;
	auto rd8 = [&](unsigned a) -> unsigned {
		if (io(a)) { auto &q = ioread[a]; if (q.empty()) return 0xff; unsigned v = q.front(); return v; }
		if (a < 0x40 || (a >= 0x40 && a < 0x1c0)) return ram[a];
		if (a < 0x2000) return irom[a];
		if (a >= 0x8000) return erom[a - 0x8000];
		return 0xff;
	};
	size_t mi = 0, bad = 0, insts = 0, extra = 0, resets = 0;
	uint64_t cyc = 0;
	t->rst = 1; t->cen = 1; t->irq = 0; t->adc = 0;
	for (int i = 0; i < 8; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
	t->rst = 0;
	while (mi < maxn && cyc < 400000000ULL) {
		t->clk = 0; t->eval();
		t->din = rd8(t->addr);
		t->eval();
		// an instruction boundary: raise the interrupt MAME took here
		if (r->ns2_hd63705__DOT__u_ctrl__DOT__ni) {
			insts++;
			// MAME's next access after any this clock makes (an instruction's
			// last write can share its clock with the boundary)
			size_t k = mi + ((t->wr || r->ns2_hd63705__DOT__u_ctrl__DOT__fetch) ? 1 : 0);
			bool irq = false, adc = false;
			if (k + 5 < mame.size() && mame[k].rw == 'W' && mame[k].addr >= 0x100 && mame[k].addr < 0x180 &&
			    mame[k + 5].rw == 'R') {
				if (mame[k + 5].addr == 0x1ff8) irq = true;
				if (mame[k + 5].addr == 0x1fea) adc = true;
			}
			t->irq = irq; t->adc = adc;
			t->eval();
			if (getenv("TRACE_NI") && mi > 2660 && mi < 2680)
				printf("ni at access %zu: this clock wr%d fetch%d addr %04x, k %zu mame[k] %c%04x, i=%d irq%d adc%d\n", mi, t->wr,
				       r->ns2_hd63705__DOT__u_ctrl__DOT__fetch, t->addr, k, mame[k].rw, mame[k].addr, r->ns2_hd63705__DOT__i, irq, adc);
		}
		bool wr = t->wr, fetch = r->ns2_hd63705__DOT__u_ctrl__DOT__fetch;
		unsigned a = t->addr, din = t->din, dout = t->dout;
		t->clk = 1; t->eval();
		cyc++;
		if (!(wr || fetch)) continue;
		// the access, against MAME's
		char rw = wr ? 'W' : 'R';
		unsigned d = wr ? dout : din;
		if (wr && (a < 0x40 || (a >= 0x40 && a < 0x1c0))) ram[a] = d;
		if (!wr && io(a)) { auto &q = ioread[a]; if (!q.empty()) q.pop_front(); }
		const Acc &m = mame[mi];
		// reads MAME's core does not make: the microcode's read before a
		// read-modify-write (CLR, BSET...), and the opcode fetch jt6805 makes
		// before it checks for an interrupt (it discards it). Harmless on RAM
		// and ROM, counted; on I/O a read with side effects would differ, so
		// it stops the run
		if (rw == 'R' && !(m.rw == 'R' && m.addr == a) && !io(a)) { extra++; continue; }
		// the 68000 resets the MCU: MAME's stream restarts at the reset vector
		if (m.rw == 'R' && m.addr == 0x1ffe && mi + 1 < mame.size() && mame[mi + 1].addr == 0x1fff &&
		    !(rw == 'R' && a == 0x1ffe)) {
			resets++;
			t->rst = 1;
			for (int i = 0; i < 8; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
			t->rst = 0;
			continue;
		}
		if (m.rw != rw || m.addr != a || m.data != d) {
			if (bad++ < 1) {
				printf("access %zu (instruction %zu): rtl %c %04x %02x, mame %c %04x %02x\n", mi, insts, rw, a, d, m.rw, m.addr, m.data);
				printf("  mame before:"); for (size_t k = mi > 6 ? mi - 6 : 0; k < mi; k++) printf(" %c%04x:%02x", mame[k].rw, mame[k].addr, mame[k].data); printf("\n");
				printf("  mame after: "); for (size_t k = mi; k < mi + 6 && k < mame.size(); k++) printf(" %c%04x:%02x", mame[k].rw, mame[k].addr, mame[k].data); printf("\n");
			}
			break;
		}
		mi++;
	}
	printf("%zu of %zu MAME accesses matched (%zu instructions, %llu clocks; %zu extra reads, %zu resets)%s\n", mi, maxn, insts,
	       (unsigned long long)cyc, extra, resets, (!bad && mi == maxn) ? ": ALL MATCH" : "");
	delete t;
	return bad ? 1 : 0;
}
