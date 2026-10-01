// ns2_controls against MAME's ports (namcos2.cpp): each control mode's
// channels, ranges, reversals and buttons, from scripted inputs.
#include "Vns2_controls.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vns2_controls *t;
static int fails = 0, checks = 0;
static void clk() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
static void frame() { t->vblank = 1; clk(); clk(); t->vblank = 0; clk(); clk(); }
static void frames(int n) { for (int i = 0; i < n; i++) frame(); }
static unsigned an(int i) { return (t->analog >> (8 * i)) & 0xff; }
static void expect(const char *what, unsigned got, unsigned want) {
	checks++;
	if (got != want) { fails++; printf("FAIL %s: got %02x want %02x\n", what, got, want); }
}
static uint16_t stick(int x, int y) { return (uint16_t)(((y & 0xff) << 8) | (x & 0xff)); }
static void reset(unsigned mode, unsigned ib = 0xff, unsigned ih = 0xff) {
	t->mode = mode; t->idle_b = ib; t->idle_h = ih; t->flip = 0; t->an_default = 0x8080808080ffffffULL;
	t->p1 = t->p2 = 0; t->start1 = t->start2 = t->coin1 = t->coin2 = t->svc1 = t->svc2 = 0;
	t->stick1 = t->stick2 = t->rstick1 = t->rstick2 = 0; t->mouse = 0; t->dial_default = 0xffffff0f;
	t->reset = 1; clk(); clk(); t->reset = 0; clk();
}
static void mouse(int dx, int dy, int btn) {
	uint32_t m = t->mouse;
	m = (((m >> 24) & 1) ^ 1) << 24 | ((dy & 0xff) << 16) | ((dx & 0xff) << 8) | ((dy < 0) << 5) | ((dx < 0) << 4) | (btn & 3);
	t->mouse = m; clk(); clk();
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vns2_controls;

	// mode 0: MAME's default ports, the defaults' analog values
	reset(0x00);
	t->p1 = 0x1f; t->start1 = 1; t->coin1 = 1; clk();   // R L D U B1
	expect("default mcub", t->mcub, (unsigned)(~0xaa) & 0xff);    // start1, P1 U D L
	expect("default mcuc", t->mcuc, (unsigned)(~0x20) & 0xff);
	expect("default mcuh", t->mcuh, (unsigned)(~0xa0) & 0xff);    // P1 R, P1 B1
	expect("default AN5", an(5), 0x80);

	// wheel and pedals (Final Lap: gear toggle)
	reset(0x05);
	frames(2);
	expect("wheel centred", an(5), 0x80); expect("brake up", an(6), 0x00); expect("accel up", an(7), 0x00);
	t->stick1 = stick(-128, 0); frames(1); expect("wheel full left (stick)", an(5), 0x01);
	t->stick1 = stick(127, 0); frames(1); expect("wheel full right (stick)", an(5), 0xff);
	t->stick1 = stick(40, 0); frames(1); expect("wheel part right", an(5), 0x80 + 40);
	t->stick1 = 0; t->p1 = 0x02; frames(32); expect("wheel d-pad left, held", an(5), 0x01);
	t->p1 = 0; frames(20); expect("wheel returns", an(5), 0x80);
	t->p1 = 0x10; frames(1); expect("accel B1 a step", an(7), 0x10);
	frames(10); expect("accel B1 held", an(7), 0x80);
	t->p1 = 0x20; frames(10); expect("accel released", an(7), 0x00); expect("brake B2 held", an(6), 0x40);
	t->p1 = 0; t->rstick1 = stick(0, -128); frames(1); expect("accel right stick up", an(7), 0x80);
	t->rstick1 = stick(0, 127); frames(1); expect("brake right stick down", an(6), 0x3f);
	t->rstick1 = 0; frames(10);
	expect("gear low", t->mcuh & 0x20, 0x20);
	t->p1 = 0x40; clk(); t->p1 = 0; clk(); expect("gear toggled", t->mcuh & 0x20, 0x00);
	t->p1 = 0x40; clk(); t->p1 = 0; clk(); expect("gear back", t->mcuh & 0x20, 0x20);
	t->p1 = 0x30; clk(); expect("pedal buttons press no port bit", t->mcuh, 0xff);

	// Steel Gunner: AN4 X1, AN5 X2, AN6 Y1, AN7 Y2
	reset(0x12);
	t->stick1 = stick(127, -128); t->stick2 = stick(-128, 127); clk();
	expect("sg AN4 = X1 right", an(4), 0xff); expect("sg AN6 = Y1 top", an(6), 0x00);
	expect("sg AN5 = X2 left", an(5), 0x00); expect("sg AN7 = Y2 bottom", an(7), 0xff);
	t->stick1 = 0; clk(); expect("sg centre", an(4), 0x80);
	expect("crosshair x centre", t->g1_x, 144); expect("crosshair y centre", t->g1_y, 112);
	t->stick1 = stick(127, 127); clk(); expect("crosshair x right", t->g1_x, 286); expect("crosshair y bottom", t->g1_y, 223);
	reset(0x12);
	expect("P2's crosshair hidden until it aims", t->g2_on, 0);
	t->stick2 = stick(40, 0); clk(); expect("P2's crosshair shown", t->g2_on, 1); t->stick2 = 0; clk();
	t->flip = 1; t->stick1 = stick(127, -128); clk(); expect("sg flipped X", an(4), 0x00); expect("sg flipped Y", an(6), 0xff);
	t->flip = 0; t->p1 = 0x30; clk(); expect("sg trigger + bomb", t->mcuh & 0x28, 0x00);
	// the mouse: it takes over from the stick when it moves
	t->p1 = 0; t->stick1 = 0; clk();
	for (int i = 0; i < 20; i++) mouse(100, 0, 0);
	expect("mouse to the right edge", an(4), 0xff);
	for (int i = 0; i < 10; i++) mouse(0, 100, 0);
	expect("mouse to the top", an(6), 0x00);
	mouse(0, 0, 1); expect("mouse button fires", t->mcuh & 0x20, 0x00);
	mouse(0, 0, 0);
	t->stick1 = stick(-128, 0); clk(); clk(); expect("stick takes back", an(4), 0x00);

	// Golly! Ghost!: AN0-3, triggers on MCUB 5 / 4, the d-pad's up not there
	reset(0x82);
	t->stick1 = stick(127, 127); clk();
	expect("gg AN0", an(0), 0xff); expect("gg AN1", an(1), 0xff); expect("gg AN2 P2 centre", an(2), 0x80);
	t->p1 = 0x08; clk(); expect("gg d-pad up is not the trigger", t->mcub & 0x20, 0x20);
	t->p1 = 0x10; t->p2 = 0x10; clk(); expect("gg triggers", t->mcub & 0x30, 0x00);
	expect("gg MCUH idle", t->mcuh, 0xff);
	// Bubble Trouble: the same channels, 255 - the position; shown turned (flip)
	reset(0xc2);
	t->flip = 1; t->stick1 = stick(127, -128); clk();
	expect("bt AN0 (flipped, reversed)", an(0), 0xff); expect("bt AN1", an(1), 0x00);

	// Lucky & Wild: guns AN4 X1, AN2 Y1, AN3 X2, AN1 Y2; wheel AN5, pedals B2 / B3
	reset(0x2a);
	t->stick1 = stick(127, -128); clk(); frames(1);
	expect("lw AN4 X1", an(4), 0xff); expect("lw AN2 Y1", an(2), 0x00); expect("lw AN5 wheel from the same stick", an(5), 0xff);
	t->p1 = 0x10; clk(); expect("lw fire", t->mcuh & 0x20, 0x00);
	t->p1 = 0x20; frames(10); expect("lw accel B2", an(7), 0x80); expect("lw B2 presses no bit", t->mcuh & 0x08, 0x08);
	t->p1 = 0x40; frames(10); expect("lw brake B3", an(6), 0x40);

	// Metal Hawk: AN5 Y, AN6 X, AN7 lever, 0x20-0xe0; B1 bit 5, B2 bit 7
	reset(0x03, 0xc0, 0xa0);
	t->stick1 = stick(-128, 127); frames(1);
	expect("mh AN6 X left", an(6), 0x20); expect("mh AN5 Y down", an(5), 0xdf);
	t->stick1 = 0; t->p1 = 0x01; frames(20); expect("mh d-pad right", an(6), 0xe0);
	clk(); expect("mh MCUH idle", t->mcuh, 0xa0); expect("mh MCUB idle", t->mcub, 0xc0);
	t->p1 = 0x3f; t->start1 = 1; clk(); expect("mh buttons", t->mcuh, 0x00); expect("mh d-pad not on MCUB, Start", t->mcub, 0x40);
	t->start1 = 0;
	t->p1 = 0x80; frames(40); expect("mh lever up (B4)", an(7), 0x20);
	t->p1 = 0; t->rstick1 = stick(0, 127); frames(1); expect("mh lever right stick", an(7), 0xdf);

	// the driving sets' digital ports: only their own bits
	reset(0x05);   // Final Lap: no Start, the DIPs stay
	t->p1 = 0x0f; t->start1 = 1; clk(); clk(); expect("fl MCUB idle under d-pad, Start", t->mcub, 0xff); expect("fl MCUH idle under d-pad", t->mcuh, 0xff);
	reset(0x15);   // Four Trax: Start on MCUB 7
	t->start1 = 1; clk(); clk(); expect("ft Start", t->mcub, 0x7f);
	reset(0x11, 0xc0, 0xff);   // Suzuka: MCUB idle 0xc0
	clk(); expect("sz MCUB idle", t->mcub, 0xc0); t->start2 = 1; clk(); clk(); expect("sz Start 2", t->mcub, 0x80);
	reset(0x21, 0xa0, 0xff);   // Dirt Fox: gears on MCUB 5 (up) / 7 (down)
	clk(); expect("df MCUB idle", t->mcub, 0xa0);
	t->p1 = 0x08; clk(); clk(); expect("df gear down (up)", t->mcub, 0x80);
	t->p1 = 0x04; clk(); clk(); expect("df gear up (down)", t->mcub, 0x20);
	t->p1 = 0; t->start1 = 1; clk(); clk(); expect("df no Start", t->mcub, 0xa0);

	// Assault: two 4-way sticks a player (MAME's assault ports). MCUB: P1 L
	// up 5, down 3, left 1 (P2 4, 2, 0); MCUH: P1 L right 7, B1 5, R up 3,
	// R down 1 (P2 6, 4, 2, 0); MCUDI0: P1 R left 3, right 1 (P2 2, 0)
	reset(0x04);
	clk(); expect("as idle MCUB", t->mcub, 0xff); expect("as idle MCUH", t->mcuh, 0xff); expect("as idle MCUDI0", t->dials & 0xff, 0x0f);
	expect("as MCUDI1-3 MAME's", t->dials >> 8, 0xffffff);
	t->stick1 = stick(0, -128); t->rstick1 = stick(0, -128); clk(); clk();
	expect("as P1 both sticks up: L up", t->mcub, 0xdf); expect("as P1 both up: R up", t->mcuh, 0xf7);
	t->stick1 = stick(127, 20); t->rstick1 = stick(-128, 30); clk(); clk();
	expect("as P1 L right (4-way)", t->mcuh, 0x7f); expect("as P1 R left", t->dials & 0xff, 0x07);
	t->stick1 = 0; t->rstick1 = stick(100, 0); clk(); clk(); expect("as P1 R right", t->dials & 0xff, 0x0d);
	t->rstick1 = 0; t->stick2 = stick(-128, 0); t->rstick2 = stick(0, 127); clk(); clk();
	expect("as P2 L left", t->mcub, 0xfe); expect("as P2 R down", t->mcuh, 0xfe);
	t->stick2 = t->rstick2 = 0;
	t->p1 = 0x08; clk(); clk(); expect("as d-pad up: both up (L)", t->mcub, 0xdf); expect("as d-pad up: both up (R)", t->mcuh, 0xf7);
	t->p1 = 0x0a; clk(); clk(); expect("as d-pad 4-way: up before left", t->mcub, 0xdf);
	t->p1 = 0x01; clk(); clk(); expect("as d-pad right: L right", t->mcuh, 0x7f); expect("as d-pad right: R right", t->dials & 0xff, 0x0d);
	t->p1 = 0x40; clk(); clk(); expect("as B3 turn left: L down", t->mcub, 0xf7); expect("as B3: R up", t->mcuh, 0xf7);
	t->p1 = 0x80; clk(); clk(); expect("as B4 turn right: L up", t->mcub, 0xdf); expect("as B4: R down", t->mcuh, 0xfd);
	t->p1 = 0x20; clk(); clk(); expect("as B2 apart: L left", t->mcub, 0xfd); expect("as B2: R right", t->dials & 0xff, 0x0d);
	t->p1 = 0x100; clk(); clk(); expect("as B5 together: L right", t->mcuh, 0x7f); expect("as B5: R left", t->dials & 0xff, 0x07);
	t->p1 = 0x10; t->p2 = 0x10; t->start1 = 1; clk(); clk(); expect("as fire both", t->mcuh, 0xcf); expect("as Start 1", t->mcub, 0x7f);
	// the other digital sets keep MAME's default ports and dials
	reset(0x00); t->rstick1 = stick(100, 0); clk(); clk(); expect("mode 0 dials untouched", t->dials & 0xff, 0x0f);

	printf("%d of %d checks passed\n", checks - fails, checks);
	return fails != 0;
}
