// The C140 (rtl/ns2_c140.sv) alone against MAME's samples: MAME's 6809
// writes to it, at MAME's times (sim/oracle/ns2_bustrace.lua with
// MP_CPU=audiocpu MP_WONLY=1 MP_TIME=1), replayed at the same clocks; its
// mixer sums compared with MAME's (NS2_C140_DUMP, tools/mame-patches).
//   ./obj_dir/Vns2_c140 SET TRACE_DIR [samples]
// TRACE_DIR: audiocpu_bus.txt and c140.raw from the same MAME run.
#include "Vns2_c140.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct W { uint64_t t; unsigned addr, data; };

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: SET TRACE_DIR [samples]\n"); return 1; }
	std::string td = argv[2];
	std::vector<uint8_t> vro;
	{
		FILE *f = fopen((std::string("../roms/") + argv[1] + "/c140.bin").c_str(), "rb");
		if (!f) { fprintf(stderr, "no c140.bin (tools/ns2_romdump.py)\n"); return 1; }
		fseek(f, 0, SEEK_END); vro.resize(ftell(f)); fseek(f, 0, SEEK_SET);
		if (fread(vro.data(), 1, vro.size(), f) != vro.size()) return 1; fclose(f);
	}
	std::vector<W> w;
	{
		FILE *f = fopen((td + "/audiocpu_bus.txt").c_str(), "r");
		char line[128], rw; unsigned a, d, m; int fr; double tm;
		while (f && fgets(line, sizeof line, f))
			if (sscanf(line, " %c %x %x %x %d %lf", &rw, &a, &d, &m, &fr, &tm) == 6 && rw == 'W' &&
			    ((a & 0xf000) == 0x5000 || (a & 0xf000) == 0x6000))
				w.push_back({(uint64_t)tm, a & 0x1ff, d & 0xff});
		if (f) fclose(f);
	}
	std::vector<int16_t> raw;
	{
		FILE *f = fopen((td + "/c140.raw").c_str(), "rb");
		if (!f) { fprintf(stderr, "no c140.raw\n"); return 1; }
		fseek(f, 0, SEEK_END); raw.resize(ftell(f) / 2); fseek(f, 0, SEEK_SET);
		if (fread(raw.data(), 2, raw.size(), f) != raw.size()) return 1; fclose(f);
	}
	size_t ns = raw.size() / 2;
	if (argc > 3 && (size_t)atol(argv[3]) < ns) ns = atol(argv[3]);
	printf("%zu writes, %zu samples\n", w.size(), ns);

	Vns2_c140 *t = new Vns2_c140;
	uint64_t cyc = 0; size_t wi = 0, si = 0; int shown = 0, bad = 0;
	bool pend = false; uint32_t pa = 0;
	auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
	t->reset = 1; for (int i = 0; i < 8; i++) tick(); t->reset = 0;
	while (si < ns) {
		t->cs = 0; t->we = 0;
		if (wi < w.size() && w[wi].t <= cyc) { t->cs = 1; t->we = 1; t->addr = w[wi].addr; t->din = w[wi].data; wi++; }
		// the voice ROM: one clock
		t->rom_valid = pend;
		if (pend) {
			size_t o = (size_t)pa * 2 % vro.size();
			t->rom_data = vro[o] << 8 | vro[o + 1];
		}
		pend = t->rom_req; pa = t->rom_addr;
		tick(); cyc++;
		if (t->sample) {
			int16_t rl = t->raw_l, rr = t->raw_r, ml = raw[2 * si], mr = raw[2 * si + 1];
			if (rl != ml || rr != mr) {
				if (shown++ < 12) printf("sample %zu (%.4f s): rtl %d %d, mame %d %d\n", si, si / 21333.0, rl, rr, ml, mr);
				bad++;
			}
			si++;
		}
	}
	printf("%zu samples, %d differ%s\n", si, bad, bad ? "" : ": ALL MATCH");
	delete t;
	return bad ? 1 : 0;
}
