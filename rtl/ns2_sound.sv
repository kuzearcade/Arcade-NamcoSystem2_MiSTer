// The sound board (namcos2.cpp sound_default_am): the 6809 at 2.048 MHz
// (E and Q from clk: 24 clocks an E cycle), the YM2151 (jt51, 3.579545 MHz),
// the C140 (rtl/ns2_c140.sv), 8 KB of RAM and the DPRAM's third port.
//   0000-3fff banked ROM (16 KB banks; c000-c001 writes select data >> 4)
//   4000-4001 YM2151           5000-51ff, 6000-61ff C140 (mirrored)
//   7000-77ff DPRAM (mirrored) 8000-9fff RAM
//   a000-bfff amplifier enable (writes ignored)
//   c000-ffff ROM (the region's first 16 KB)
// IRQ: MAME's periodic 120 Hz (irq0_line_hold) from power-on, held until
// the 6809 fetches its vector; FIRQ: the C140's INT1. The YM2151's IRQ is not
// wired (MAME comments it out).
module ns2_sound #(parameter C140_MAME_RATE = 0) (
	input             clk,
	input             reset,
	input             run,            // the master's C148 ext1 bit 0
	// the sound ROM (128 or 256 KB): data one clock after the address, or
	// when rom_ready (a cache: a miss stretches the E cycle)
	output     [17:0] rom_addr,
	input      [7:0]  rom_data,
	input             rom_ready,
	output            rom_rd,
	output            rom_hold,       // this clock, the cycle waits for the ROM's cache
	input             stop,           // every CPU stops (any one's rom_hold)
	input             pause,          // the OSD's pause: the YM2151's clock, the C140 and the 120 Hz timer stop too
	output            rom_smp,        // rom_rd and the address have settled (ns2_rom_cache SAMPLED)
	// the DPRAM's sound port
	output reg [10:0] dp_addr,
	output reg [7:0]  dp_dout,
	output reg        dp_we,
	input      [7:0]  dp_din,
	// audio
	output signed [15:0] ym_left,
	output signed [15:0] ym_right,
	output            ym_sample,
	// the C140 and its voice ROM (the "c140" region's words)
	output            vrom_req,
	output     [19:0] vrom_addr,
	input             vrom_valid,
	input      [15:0] vrom_data,
	output signed [15:0] c140_left,
	output signed [15:0] c140_right,
	output signed [15:0] c140_raw_l,
	output signed [15:0] c140_raw_r,
	output            c140_sample,
	// debug
	output     [15:0] dbg_addr,
	output            dbg_wr,
	output     [7:0]  dbg_dout
);
	// E and Q: quarters of 6 clocks; falling E starts a cycle
	reg [4:0] ph;
	// a ROM read not ready holds the cycle at its last clock (rom_hold); any
	// CPU's hold stops every CPU (stop: the board's lockstep, NS2-14)
	wire rom_wait;
	assign rom_hold = ph == 5'd23 && rom_wait;
	always @(posedge clk) ph <= stop ? ph : ph == 5'd23 ? 5'd0 : ph + 1'd1;
	wire fallE = ph == 5'd0 && !stop, fallQ = ph == 5'd18 && !stop;
	// the CPU's registers change on fallE; its address also follows its data
	// input (ADDR = addr_nxt). From five clocks after fallE to the cycle's end
	// the cache takes it, and is ready only for the address it took
	// (ns2_rom_cache SAMPLED; the SDC's 4-cycle multicycle paths)
	assign rom_smp = ph >= 5'd5;

	// 3.579545 MHz for the YM2151 (the fraction of 49.152 MHz)
	reg [26:0] yacc;
	reg        ycen, ycen_p1_t, ycen_p1;
	always @(posedge clk) begin
		ycen <= 1'b0; ycen_p1 <= 1'b0;
		if (pause) ;
		else if (yacc + 27'd3579545 >= 27'd49152000) begin
			yacc <= yacc + 27'd3579545 - 27'd49152000; ycen <= 1'b1;
			ycen_p1_t <= !ycen_p1_t; ycen_p1 <= ycen_p1_t;
		end else yacc <= yacc + 27'd3579545;
	end

	// 120 Hz from power-on: 409600 clocks
	reg [18:0] tdiv;
	reg        irq;
	wire [15:0] a;
	wire        rnw, bs, ba;
	wire [7:0]  cpu_do;
	reg  [7:0]  cpu_di;
	always @(posedge clk) begin
		if (reset) begin tdiv <= 0; irq <= 1'b0; end
		else begin
			if (!pause) tdiv <= tdiv == 19'd409599 ? 19'd0 : tdiv + 1'd1;
			if (tdiv == 19'd409599 && !pause) irq <= 1'b1;
			// the vector fetch (BS, not BA) of FFF8 takes it
			if (fallE && bs && !ba && a == 16'hfff8) irq <= 1'b0;
		end
	end

	wire        int1;
	mc6809is #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_cpu (
		.CLK(clk), .fallE_en(fallE), .fallQ_en(fallQ),
		.D(cpu_di), .DOut(cpu_do), .ADDR(a), .RnW(rnw), .BS(bs), .BA(ba),
		.nIRQ(!irq), .nFIRQ(!int1), .nNMI(1'b1),
		.AVMA(), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(!(reset || !run)), .nDMABREQ(1'b1), .RegData());
	assign dbg_addr = a; assign dbg_wr = fallE && !rnw; assign dbg_dout = cpu_do;

	reg  [3:0] bank;
	reg  [7:0] ram [0:8191];
	reg  [7:0] ram_q;
	wire sel_rom_b = a[15:14] == 2'b00;
	wire sel_ym    = a[15:1] == 15'h2000;
	wire sel_c140  = a[15:12] == 4'h5 || a[15:12] == 4'h6;
	wire sel_dp    = a[15:12] == 4'h7;
	wire sel_ram   = a[15:13] == 3'b100;
	wire sel_rom_f = a[15:14] == 2'b11;
	assign rom_addr = sel_rom_b ? {bank, a[13:0]} : {4'd0, a[13:0]};
	assign rom_rd   = (sel_rom_b || sel_rom_f) && rnw;
	assign rom_wait = rom_rd && !rom_ready;

	// the chips' strobes: one clock, on the falling E that ends the cycle
	wire wr_e = fallE && !rnw;
	wire [7:0] ym_q, c140_q;
	// the YM2151's writes through a FIFO (ns2_ym_fifo, NS2-26)
	wire       ym_wr;
	wire [8:0] ym_wq;
	ns2_ym_fifo ym_fifo (.clk(clk), .reset(reset), .ycen(ycen), .we(wr_e && sel_ym), .a0(a[0]), .din(cpu_do),
		.wr(ym_wr), .wq(ym_wq));
	jt51 u_ym (
		.rst(reset), .clk(clk), .cen(ycen), .cen_p1(ycen_p1),
		.cs_n(!ym_wr), .wr_n(1'b0), .a0(ym_wq[8]), .din(ym_wq[7:0]), .dout(ym_q),
		.ct1(), .ct2(), .irq_n(), .sample(ym_sample), .left(), .right(), .xleft(ym_left), .xright(ym_right));
	ns2_c140 #(.MAME_RATE(C140_MAME_RATE)) u_c140 (.clk(clk), .reset(reset), .hold(pause), .cs(wr_e && sel_c140), .we(1'b1),
		.addr(a[8:0]), .din(cpu_do), .dout(c140_q), .int1(int1),
		.rom_req(vrom_req), .rom_addr(vrom_addr), .rom_valid(vrom_valid), .rom_data(vrom_data),
		.left(c140_left), .right(c140_right), .raw_l(c140_raw_l), .raw_r(c140_raw_r), .sample(c140_sample));

	always @(posedge clk) begin
		ram_q <= ram[a[12:0]];
		if (wr_e && sel_ram) ram[a[12:0]] <= cpu_do;
		if (wr_e && a[15:1] == 15'h6000) bank <= cpu_do[7:4];
		if (reset) bank <= 0;
		dp_addr <= a[10:0]; dp_dout <= cpu_do;
		dp_we <= wr_e && sel_dp;
	end
	always @(*) begin
		if (sel_rom_b || sel_rom_f) cpu_di = rom_data;
		else if (sel_ym)   cpu_di = ym_q;
		else if (sel_c140) cpu_di = c140_q;
		else if (sel_dp)   cpu_di = dp_din;
		else if (sel_ram)  cpu_di = ram_q;
		else cpu_di = 8'hff;
	end
endmodule
