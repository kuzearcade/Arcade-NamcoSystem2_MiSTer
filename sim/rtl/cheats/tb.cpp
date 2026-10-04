// NS2-30: cheats.sv (10 slots, 3 actions) with a set's table, every slot on,
// a model back door (paused 8 clocks after pause_cpu, a RAM read a clock
// after its address): one frame's writes against the table's actions
#include "Vcheats.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <map>
#include <vector>
#include <string>
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string cmd = std::string("python3 -c \"import sys; sys.path.insert(0,'../../../tools'); import ns2_extras as X; r=X.cheats('") + argv[1] + "'); print(' '.join(str(b) for row in r[0] for b in row) if r else '')\"";
	FILE *p = popen(cmd.c_str(), "r"); std::vector<int> tbl; int b; while (fscanf(p, "%d", &b) == 1) tbl.push_back(b); pclose(p);
	if (tbl.empty()) { printf("no cheats\n"); return 1; }
	Vcheats *t = new Vcheats;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->reset = 1; tick(); tick(); t->reset = 0;
	// the table's download, a byte a write
	t->ioctl_download = 1; t->ioctl_index = 5;
	for (size_t i = 0; i < tbl.size(); i++) { t->ioctl_addr = i; t->ioctl_dout = tbl[i]; t->ioctl_wr = 1; tick(); t->ioctl_wr = 0; tick(); }
	t->ioctl_download = 0; tick();
	std::map<uint32_t, uint8_t> ram; for (uint32_t a = 0; a < 0x420000; a += 1) {}   // reads default to 0x5a
	auto rd = [&](uint32_t a) { return ram.count(a) ? ram[a] : (uint8_t)0x5a; };
	t->enable = 0x3ff; t->vblank = 0; tick();
	t->vblank = 1;
	int paused_cnt = 0; uint32_t q_addr = 0; std::vector<std::pair<uint32_t,int>> writes;
	for (int c = 0; c < 5000; c++) {
		t->paused = paused_cnt >= 8;
		t->ram_dout = rd(q_addr);
		tick();
		paused_cnt = t->pause_cpu ? paused_cnt + 1 : 0;
		q_addr = t->ram_addr;
		if (t->ram_write) { writes.push_back({t->ram_addr, t->ram_din}); ram[t->ram_addr] = t->ram_din; }
	}
	// expected: per slot with a count, per action
	std::vector<std::pair<uint32_t,int>> exp; std::map<uint32_t, uint8_t> m;
	for (int s = 0; s < 10; s++) {
		int base = s * 20, n = tbl[base];
		for (int a = 0; a < n; a++) {
			int o = base + 2 + a * 6; uint32_t ad = tbl[o] << 16 | tbl[o + 1] << 8 | tbl[o + 2]; int k = tbl[o + 3], hi = tbl[o + 4], lo = tbl[o + 5];
			auto r = [&](uint32_t x) { return m.count(x) ? m[x] : (uint8_t)0x5a; };
			if (k == 1) { exp.push_back({ad, hi}); m[ad] = hi; exp.push_back({ad + 1, lo}); m[ad + 1] = lo; }
			else if (k == 2) { int v = (r(ad) & ~hi) | (lo & hi); exp.push_back({ad, v}); m[ad] = v; }
			else { exp.push_back({ad, lo}); m[ad] = lo; }
		}
	}
	int bad = writes.size() != exp.size();
	for (size_t i = 0; i < writes.size() && i < exp.size(); i++)
		if (writes[i] != exp[i]) { if (bad++ < 5) printf("write %zu: %06x=%02x, expected %06x=%02x\n", i, writes[i].first, writes[i].second, exp[i].first, exp[i].second); }
	printf("%s: available %03x, %zu writes, %zu expected, %s; pause released %d\n", argv[1], (int)t->available, writes.size(), exp.size(), bad ? "MISMATCH" : "all match", !t->pause_cpu);
	return bad != 0;
}
