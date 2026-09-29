// NS2-22: ns2_flipbuf alone, with a model of the DDR port (random wait
// states and read latency; SLOW=1 for 1 in 2 and 50-350 clocks). A 384 x 264
// stream, a pixel every 16 clocks, the flip switched on and off over 12
// frames: every active pixel must be the previous frame turned 180 degrees
// when the flip has held for two frames, else the frame itself; and the
// buffer must let go of the port during a frame with the flip off.
//   make && ./obj_dir/Vns2_flipbuf; SLOW=1 ./obj_dir/Vns2_flipbuf
#include "Vns2_flipbuf.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <map>
#include <deque>
#include <cstring>
// the stream: 384 x 264, a pixel every 16 clocks; active 288 x 224 from (0,0)
static uint32_t pix(int f, int x, int y) { return ((f * 7 + x * 131 + y * 977) ^ (x << 12) ^ (y << 4)) & 0xffffff; }
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Vns2_flipbuf *t = new Vns2_flipbuf;
	std::map<uint32_t, uint64_t> mem;
	std::deque<std::pair<uint32_t,int>> rq;   // pending reads: addr, words
	int wr_left = 0; uint32_t wr_addr = 0; int lat = 0;
	int errors = 0, checked = 0, frames = 12; int owned_off = 0;
	auto en = [](int f) { return f >= 0 && !(f == 4 || f == 5 || f == 9); };
	int out_x = 0, out_y = 0, out_f = 0; bool out_de_d = false, out_vb_d = true;
	const char *e = getenv("SLOW"); bool slow = e && !strcmp(e, "1");
	int busy_1in = slow ? 2 : 4, lat0 = slow ? 50 : 5, latr = slow ? 300 : 20;
	srand(1);
	t->enable = 1;
	for (int f = 0; f < frames; f++)
	for (int y = 0; y < 264; y++)
	for (int x = 0; x < 384; x++)
	for (int c = 0; c < 16; c++) {
		t->enable = en(f);
		bool act = x < 288 && y < 224;
		t->ce_in = (c == 0);
		t->rgb_in = act ? pix(f, x, y) : 0;
		t->hb_in = !(x < 288); t->vb_in = !(y < 224);
		t->hs_in = x >= 320 && x < 352; t->vs_in = y == 240; t->vb_hs_in = t->vb_in;
		// the DDR: random wait states, read data a few clocks later
		t->DDRAM_BUSY = (rand() % busy_1in) == 0;
		t->DDRAM_DOUT_READY = 0;
		if (!rq.empty()) {
			if (lat > 0) lat--;
			else if (rand() % 3) {
				auto &r = rq.front();
				t->DDRAM_DOUT = mem.count(r.first) ? mem[r.first] : 0xdeadbeefdeadbeefULL;
				t->DDRAM_DOUT_READY = 1;
				r.first++; if (--r.second == 0) { rq.pop_front(); lat = lat0 + rand() % latr; }
			}
		}
		t->clk = 0; t->eval();
		// sample the master's outputs at the edge
		if (!t->DDRAM_BUSY) {
			if (t->DDRAM_WE) {
				if (wr_left == 0) { wr_addr = t->DDRAM_ADDR; wr_left = t->DDRAM_BURSTCNT; }
				mem[wr_addr++] = t->DDRAM_DIN; wr_left--;
			}
			if (t->DDRAM_RD) { rq.push_back({t->DDRAM_ADDR, t->DDRAM_BURSTCNT}); if (rq.size() == 1) lat = lat0 + rand() % latr; }
		}
		t->clk = 1; t->eval();
		if (f == 6 && y < 224 && t->owns) owned_off++;   // frame 6: the flip off (it returns at its blank)
		// the output, one clock later
		if (t->ce_out) {
			bool de = !t->hb_out && !t->vb_out;
			if (t->vb_out && !out_vb_d) { out_f++; out_y = 0; }
			if (de) {
				// frame out_f shows frame out_f - 1 turned (from the third frame on)
				int g = out_f;
				bool turned = en(g - 1) && en(g - 2);
				uint32_t want = turned ? pix(g - 1, 287 - out_x, 223 - out_y) : pix(g, out_x, out_y);
				checked++;
				if (t->rgb_out != want) { if (errors < 10) printf("frame %d (%d,%d): %06x want %06x %s\n", g, out_x, out_y, t->rgb_out, want, turned ? "turned" : "straight"); errors++; }
				out_x++;
			}
			if (out_de_d && !de) { out_x = 0; out_y++; }
			out_de_d = de; out_vb_d = t->vb_out;
		}
	}
	printf("the port held in an off frame's picture: %d clocks\n", owned_off); printf("checked %d pixels, %d wrong\n", checked, errors);
	return (errors || owned_off) ? 1 : 0;
}
