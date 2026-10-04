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
	output     [7:0]  dbg_dout,
	// the savestate (M5): the 6809's park (rtl/savestate/ss_m6809_park.sv,
	// NMI, its monitor at a000, where writes are ignored); at_head: the
	// falling E that fetches the monitor's loop. While ss_on the snapshot
	// owns ss_ram the RAM (bytes), ss_c140r the C140's registers (bytes),
	// ss_c140v its voices (ns2_c140), ss_ym the YM2151's register shadow,
	// ss_reg the registers (0 bank, 1-2 the YM's clock, 3-4 the 120 Hz timer
	// and IRQ, 5 the 6809's S, 6 the YM's address, 7 PMD, 8-9 the key-ons,
	// 16-24 the C140's globals); ss_q a clock or two after ss_a. ss_replay:
	// the YM2151 is given its shadow again (a load), ss_replay_done; c140_idle
	input             park_req,
	input             resume,
	output            parked,
	output            at_head,
	input             ss_on,
	input      [12:0] ss_a,
	input             ss_ram, ss_c140r, ss_c140v, ss_ym, ss_reg,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_q,
	input             ss_replay,
	output reg        ss_replay_done,
	output            c140_idle,
	output            e_fall          // the falling E (the freeze's point when the 6809 is held in reset)
);
	// E and Q: quarters of 6 clocks; falling E starts a cycle
	reg [4:0] ph;
	// a ROM read not ready holds the cycle at its last clock (rom_hold); any
	// CPU's hold stops every CPU (stop: the board's lockstep, NS2-14)
	wire rom_wait;
	assign rom_hold = ph == 5'd23 && rom_wait;
	// (reset with the 68000s' phases: the savestate's freeze relies on their
	// fixed offset)
	always @(posedge clk) ph <= reset ? 5'd0 : stop ? ph : ph == 5'd23 ? 5'd0 : ph + 1'd1;
	wire fallE = ph == 5'd0 && !stop, fallQ = ph == 5'd18 && !stop;
	assign e_fall = fallE;
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
		if (ss_wr && ss_reg && ss_a[4:0] == 5'd1) yacc[15:0] <= ss_wdata;
		else if (ss_wr && ss_reg && ss_a[4:0] == 5'd2) {ycen_p1_t, yacc[26:16]} <= ss_wdata[11:0];
		else if (pause) ;
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
		else if (ss_wr && ss_reg && ss_a[4:0] == 5'd3) tdiv[15:0] <= ss_wdata;
		else if (ss_wr && ss_reg && ss_a[4:0] == 5'd4) {irq, tdiv[18:16]} <= ss_wdata[3:0];
		else begin
			if (!pause) tdiv <= tdiv == 19'd409599 ? 19'd0 : tdiv + 1'd1;
			if (tdiv == 19'd409599 && !pause) irq <= 1'b1;
			// the vector fetch (BS, not BA) of FFF8 takes it
			if (fallE && bs && !ba && a == 16'hfff8) irq <= 1'b0;
		end
	end

	wire        int1;
	wire        nmi_park_n, sel_mon;
	wire [7:0]  mon_q;
	wire [15:0] park_s;
	ss_m6809_park #(.MON_BASE(8'ha0)) u_park (
		.clk(clk), .reset(reset || !run), .fallE(fallE),
		.park_req(park_req), .parked(parked), .resume(resume),
		.a(a), .rnw(rnw), .bs(bs), .ba(ba), .dout(cpu_do), .game_nmi_n(1'b1),
		.nmi_park_n(nmi_park_n), .sel_mon(sel_mon), .mon_data(mon_q), .at_head(at_head),
		.ss_wr(ss_wr && ss_reg && ss_a[4:0] == 5'd5), .ss_wdata(ss_wdata), .ss_rdata(park_s));
	mc6809is #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_cpu (
		.CLK(clk), .fallE_en(fallE), .fallQ_en(fallQ),
		.D(cpu_di), .DOut(cpu_do), .ADDR(a), .RnW(rnw), .BS(bs), .BA(ba),
		.nIRQ(!irq), .nFIRQ(!int1), .nNMI(nmi_park_n),
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
	// (the park's NMI vector fetch at fffc reads the ROM too: its data is the
	// monitor's, the cache's fetch harmless)
	assign rom_rd   = (sel_rom_b || sel_rom_f) && rnw;
	assign rom_wait = rom_rd && !rom_ready;

	// the chips' strobes: one clock, on the falling E that ends the cycle
	wire wr_e = fallE && !rnw;
	wire [7:0] ym_q, c140_q;
	// the YM2151's register shadow (the savestate's, M5): every data write
	// the CPU makes, at its address; 0x19's two registers apart (AMD in the
	// shadow, PMD in pmd_r), and the key-on state of each channel
	(* ramstyle = "M10K" *) reg [7:0] ysh [0:255];
	reg  [7:0] ysh_q, ym_asel;
	reg  [6:0] pmd_r;
	reg  [3:0] kon [0:7];
	wire       ym_dw = wr_e && sel_ym && a[0];
	reg        replaying;
	reg  [7:0] rp_ra;                       // the shadow's read address during the replay
	wire [7:0] ysh_a  = ss_on ? ss_a[7:0] : replaying ? rp_ra : ym_asel;
	wire       ysh_we = ss_on ? ss_wr && ss_ym : ym_dw && !(ym_asel == 8'h19 && cpu_do[7]);
	wire [7:0] ysh_d  = ss_on ? ss_wdata[7:0] : cpu_do;
	always @(posedge clk) begin
		if (ysh_we) ysh[ysh_a] <= ysh_d;
		ysh_q <= ysh[ysh_a];
	end
	always @(posedge clk) begin
		if (wr_e && sel_ym && !a[0]) ym_asel <= cpu_do;
		if (ym_dw && ym_asel == 8'h19 && cpu_do[7]) pmd_r <= cpu_do[6:0];
		if (ym_dw && ym_asel == 8'h08) kon[cpu_do[2:0]] <= cpu_do[6:3];
		if (ss_wr && ss_reg) case (ss_a[4:0])
			5'd6: ym_asel <= ss_wdata[7:0];
			5'd7: pmd_r <= ss_wdata[6:0];
			5'd8: {kon[3], kon[2], kon[1], kon[0]} <= ss_wdata;
			5'd9: {kon[7], kon[6], kon[5], kon[4]} <= ss_wdata;
			default: ;
		endcase
	end

	// the replay (a load): the FIFO emptied, then the operators' and channels'
	// registers (0x20-0xff), the noise, LFO (AMD, then PMD), CT/W, the timers
	// and their control, and each channel's key-on last, through the FIFO
	// with the YM2151 on a clock of its own (the board's is held)
	reg  [8:0] rp_n;                        // the register being replayed (241 in all)
	reg  [2:0] rp_st;
	reg  [3:0] rp_div;
	reg        rp_ce, rp_p1t, rp_p1;
	reg        rp_we, rp_a0, rp_flush;
	reg  [7:0] rp_d, rp_reg;
	localparam RP_IDLE = 3'd0, RP_SET = 3'd1, RP_RD = 3'd2, RP_ADDR = 3'd3, RP_DATA = 3'd4, RP_WAIT = 3'd5, RP_DONE = 3'd6;
	wire [3:0] rp_t = rp_n[3:0] - 4'd0;     // within the tail (rp_n - 224)
	wire [8:0] rp_k = rp_n - 9'd224;
	function [7:0] tail_reg(input [3:0] k);
		case (k) 0: tail_reg = 8'h0f; 1: tail_reg = 8'h18; 2: tail_reg = 8'h19; 3: tail_reg = 8'h19; 4: tail_reg = 8'h1b;
		         5: tail_reg = 8'h10; 6: tail_reg = 8'h11; 7: tail_reg = 8'h12; default: tail_reg = 8'h14; endcase
	endfunction
	wire       ym_empty;
	always @(posedge clk) begin
		rp_we <= 1'b0; rp_flush <= 1'b0; rp_ce <= 1'b0; rp_p1 <= 1'b0;
		if (replaying) begin
			rp_div <= rp_div == 4'd13 ? 4'd0 : rp_div + 1'd1;
			if (rp_div == 4'd0) begin rp_ce <= 1'b1; rp_p1t <= !rp_p1t; rp_p1 <= rp_p1t; end
		end
		if (reset || !ss_replay) begin
			rp_st <= RP_IDLE; replaying <= 1'b0; ss_replay_done <= 1'b0;
		end else case (rp_st)
			RP_IDLE: begin replaying <= 1'b1; rp_flush <= 1'b1; rp_n <= 9'd0; rp_div <= 4'd0; rp_st <= RP_SET; end
			RP_SET: begin
				// the register and where its data is
				if (rp_n < 9'd224) begin rp_reg <= 8'h20 + rp_n[7:0]; rp_ra <= 8'h20 + rp_n[7:0]; end
				else if (rp_n < 9'd233) begin rp_reg <= tail_reg(rp_k[3:0]); rp_ra <= tail_reg(rp_k[3:0]); end
				else rp_reg <= 8'h08;
				rp_st <= RP_RD;
			end
			RP_RD: rp_st <= RP_ADDR;            // the shadow's read
			RP_ADDR: begin
				rp_we <= 1'b1; rp_a0 <= 1'b0; rp_d <= rp_reg;
				rp_st <= RP_DATA;
			end
			RP_DATA: begin
				rp_we <= 1'b1; rp_a0 <= 1'b1;
				rp_d <= rp_n == 9'd227 ? {1'b1, pmd_r} : rp_n >= 9'd233 ? {1'b0, kon[rp_k[2:0] - 3'd1], rp_k[2:0] - 3'd1} : ysh_q;
				rp_n <= rp_n + 1'd1;
				rp_st <= rp_n == 9'd240 ? RP_WAIT : RP_SET;
			end
			RP_WAIT: if (ym_empty && !rp_we) rp_st <= RP_DONE;
			RP_DONE: begin replaying <= 1'b0; ss_replay_done <= 1'b1; end
			default: rp_st <= RP_IDLE;
		endcase
	end

	// the YM2151's writes through a FIFO (ns2_ym_fifo, NS2-26)
	wire       ym_wr;
	wire [8:0] ym_wq;
	wire       ycen_y = replaying ? rp_ce : ycen, ycen_p1_y = replaying ? rp_p1 : ycen_p1;
	ns2_ym_fifo ym_fifo (.clk(clk), .reset(reset), .ycen(ycen_y),
		.we(replaying ? rp_we : wr_e && sel_ym), .a0(replaying ? rp_a0 : a[0]), .din(replaying ? rp_d : cpu_do),
		.wr(ym_wr), .wq(ym_wq), .flush(rp_flush), .empty(ym_empty));
	jt51 u_ym (
		.rst(reset), .clk(clk), .cen(ycen_y), .cen_p1(ycen_p1_y),
		.cs_n(!ym_wr), .wr_n(1'b0), .a0(ym_wq[8]), .din(ym_wq[7:0]), .dout(ym_q),
		.ct1(), .ct2(), .irq_n(), .sample(ym_sample), .left(), .right(), .xleft(ym_left), .xright(ym_right));
	wire [7:0]  c140_vq;
	wire [15:0] c140_gq;
	wire        c140_ss = ss_on && (ss_c140r || ss_c140v || (ss_reg && ss_a[4]));
	ns2_c140 #(.MAME_RATE(C140_MAME_RATE)) u_c140 (.clk(clk), .reset(reset), .hold(pause), .cs(wr_e && sel_c140), .we(1'b1),
		.addr(ss_on ? (ss_c140r ? ss_a[8:0] : {5'd0, ss_a[3:0]}) : a[8:0]), .din(cpu_do), .dout(c140_q), .int1(int1),
		.ss_on(c140_ss), .ss_va(ss_a[9:0]), .ss_rwr(ss_wr && ss_c140r), .ss_vwr(ss_wr && ss_c140v), .ss_gwr(ss_wr && ss_reg && ss_a[4]),
		.ss_wdata(ss_wdata), .ss_vq(c140_vq), .ss_gq(c140_gq), .idle(c140_idle),
		.rom_req(vrom_req), .rom_addr(vrom_addr), .rom_valid(vrom_valid), .rom_data(vrom_data),
		.left(c140_left), .right(c140_right), .raw_l(c140_raw_l), .raw_r(c140_raw_r), .sample(c140_sample));

	wire [12:0] ram_a = ss_on ? ss_a : a[12:0];
	always @(posedge clk) begin
		ram_q <= ram[ram_a];
		if (ss_on ? ss_wr && ss_ram : wr_e && sel_ram) ram[ram_a] <= ss_on ? ss_wdata[7:0] : cpu_do;
		if (wr_e && a[15:1] == 15'h6000) bank <= cpu_do[7:4];
		if (ss_wr && ss_reg && ss_a[4:0] == 5'd0) bank <= ss_wdata[3:0];
		if (reset) bank <= 0;
		dp_addr <= a[10:0]; dp_dout <= cpu_do;
		dp_we <= wr_e && sel_dp;
	end
	// the snapshot's read (the RAMs a clock after ss_a)
	always @(*) begin
		if (ss_ram) ss_q = {8'h00, ram_q};
		else if (ss_c140r) ss_q = {8'h00, c140_q};
		else if (ss_c140v) ss_q = {8'h00, c140_vq};
		else if (ss_ym) ss_q = {8'h00, ysh_q};
		else case (ss_a[4:0])
			5'd0: ss_q = {12'd0, bank};
			5'd1: ss_q = yacc[15:0];
			5'd2: ss_q = {4'd0, ycen_p1_t, yacc[26:16]};
			5'd3: ss_q = tdiv[15:0];
			5'd4: ss_q = {12'd0, irq, tdiv[18:16]};
			5'd5: ss_q = park_s;
			5'd6: ss_q = {8'd0, ym_asel};
			5'd7: ss_q = {9'd0, pmd_r};
			5'd8: ss_q = {kon[3], kon[2], kon[1], kon[0]};
			5'd9: ss_q = {kon[7], kon[6], kon[5], kon[4]};
			default: ss_q = ss_a[4] ? c140_gq : 16'h0000;
		endcase
	end
	always @(*) begin
		if (sel_mon) cpu_di = mon_q;
		else if (sel_rom_b || sel_rom_f) cpu_di = rom_data;
		else if (sel_ym)   cpu_di = ym_q;
		else if (sel_c140) cpu_di = c140_q;
		else if (sel_dp)   cpu_di = dp_din;
		else if (sel_ram)  cpu_di = ram_q;
		else cpu_di = 8'hff;
	end
endmodule
