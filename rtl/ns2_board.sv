// The whole board for M2's simulation (sim/rtl/ns2_frames): the two 68000s
// (ns2_main), the video (ns2_video), the I/O MCU (ns2_c65, or ns2_c68 with
// mcu_c68), the sound board
// (ns2_sound) and the 2 KB DPRAM they share. ROMS = 0 (M2): the ROMs are
// arrays (public, loaded by the testbench), read in a clock. ROMS = 1 (M3):
// each CPU's ROM is a cache (ns2_rom_cache) over an SDRAM client of ns2_mem,
// and the C140's voices a client of its own; the ports below. Either way the
// graphics ROM streams are ports.
// Line events, at the start of the line (MAME's scanline timer):
//   200 the MCU's IRQ1, 240 both C148s' VBLANK, (reg5 - 32) & 0xff POSIRQ.
module ns2_board #(parameter C140_MAME_RATE = 0, parameter ROMS = 0,
	parameter HAS_SPRA = 1, parameter HAS_ROZ = 1, parameter HAS_C45 = 1, parameter HAS_C169 = 1, parameter HAS_C355 = 1,
	parameter WRAM_SD = 0) (
	input             clk,
	input             reset,
	input      [2:0]  board,
	input             mcu_c68,       // the I/O MCU is a C68 (M37450) instead of a C65
	input             tile_fl2,
	input             spr_fl,
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	// inputs (MAME's ports)
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,
	input      [63:0] analog,
	input             dbg_stall,      // ROMS = 0: the master's ROM not ready (M2's stall experiment)
	output     [3:0]  dbg_holds,      // the lockstep's sources: {6809, C68, C65, 68000s}
	// video out
	output     [7:0]  red, green, blue,
	output            ce_pix,         // the pixel clock enable (red/green/blue are the pixel at hcnt/vcnt)
	output     [8:0]  out_x,
	output     [7:0]  out_y,
	output            out_valid,
	output     [8:0]  hcnt,
	output     [8:0]  vcnt,
	// the graphics ROM streams (as ns2_video)
	output            tile_req,  output [18:0] tile_addr,  input tile_ack,  input tile_valid,  input [63:0] tile_data,
	output            tmask_req, output [18:0] tmask_addr, input tmask_ack, input tmask_valid, input [7:0]  tmask_data,
	output            roz_req,   output [18:0] roz_addr,   input roz_ack,   input roz_valid,   input [63:0] roz_data,
	output            spr_req,   output [19:0] spr_addr,   input spr_ack,   input spr_valid,   input [63:0] spr_data,
	output            c169_req,  output [20:0] c169_addr,  input c169_ack,  input c169_valid,  input [63:0] c169_data,
	output            c169m_req, output [18:0] c169m_addr, input c169m_ack, input c169m_valid, input [7:0]  c169m_data,
	// audio
	output signed [15:0] ym_left, ym_right,
	output signed [15:0] c140_left, c140_right, c140_raw_l, c140_raw_r,
	output            c140_sample,
	// debug
	output            m_as, s_as,
	output     [23:1] m_addr, s_addr,
	output            m_rnw, s_rnw,
	output     [15:0] m_wdata, s_wdata,
	output     [1:0]  m_ds, s_ds,
	output     [15:0] m_rdata, s_rdata,
	output            m_dtack, s_dtack,
	output     [15:0] mcu_addr, snd_addr,
	output            mcu_wr, snd_wr,
	// ROMS = 1: ns2_mem's clients (bursts of four words)
	output            mprog_req, output [14:0] mprog_addr, input mprog_ack, input mprog_valid,
	output            sprog_req, output [14:0] sprog_addr, input sprog_ack, input sprog_valid,
	output            drom_req,  output [17:0] drom_addr,  input drom_ack,  input drom_valid,
	output            aud_req,   output [14:0] aud_addr,   input aud_ack,   input aud_valid,
	output            mcu_req,   output [12:0] mcu_addr_m, input mcu_ack,   input mcu_valid,
	output            c140_req,  output [17:0] c140_addr,  input c140_ack,  input c140_valid,
	input      [63:0] bank0_data,
	input      [63:0] bank1_data,
	// WRAM_SD (ROMS = 1): bank 1 clients: [0] the master's work RAM, [1] the
	// slave's, [2] the C139's RAM
	output     [2:0]  wram_req,
	output     [2:0]  wram_we,
	output     [44:0] wram_addr,      // words in each 64 KB
	output     [47:0] wram_din,
	output     [5:0]  wram_dsn,
	input      [2:0]  wram_ack,
	input      [2:0]  wram_valid,
	// the download's loads: the C45 CLUT and the default NVRAM
	input             clut_we,
	input      [7:0]  clut_addr,
	input      [7:0]  clut_data,
	input             nv_we,
	input      [12:0] nv_addr,
	input      [7:0]  nv_data,
	output     [7:0]  nv_q,           // the EEPROM at nv_addr, a clock later (the NVRAM's save)
	output            nv_cpu_we,      // the game writes the EEPROM
	output            overrun,        // the video: a line not rendered in time (ns2_video)
	output     [5:0]  overrun_src,
	output     [11:0] line_busy_max,
	output            mcu_tap, mcu_sync, mcu_cen,  // the C68's bus (debug)
	output     [7:0]  mcu_din,
	output     [7:0]  mcu_dout, snd_dout,
	output            sound_run, sub_run
);
	wire [17:1] mra, sra;
	wire [20:1] dra;
	wire [17:0] ara;
	wire [12:0] ira;
	wire [14:0] ira68;
	wire [14:0] era;
	wire [15:0] mrq, srq, drq;
	wire [7:0]  arq, irq_q, erq;
	wire        m_rd, s_rd, d_rd, a_rd, mcu_rd;
	wire        m_ready, s_ready, d_ready, a_ready, mcu_ready;
	// the CPUs' lockstep (NS2-14): any CPU waiting for its ROM's cache stops
	// them all, so the caches never change the CPUs' timing against each other
	wire        hold_main, hold_65, hold_68, hold_snd;
	wire        cpu_stop = hold_main || hold_65 || hold_68 || hold_snd;
	assign dbg_holds = {hold_snd, hold_68, hold_65, hold_main};
	wire        a_smp, smp_65, smp_68;     // the slow CPUs' ROM address phases (ns2_rom_cache SAMPLED)
	wire        mcu_smp = mcu_c68 ? smp_68 : smp_65;
	wire [15:0] a_65, a_68;
	wire [15:0] mcu_a = mcu_c68 ? a_68 : a_65;       // the MCU's bus address
	// the voice ROM
	wire        vr_req;
	wire [19:0] vr_addr;
	reg         vr_valid;
	reg  [15:0] vr_q;
	generate if (ROMS == 0) begin : g_arrays
		// ROMs (public, loaded by the testbench)
		reg [15:0] mrom [0:131071] /*verilator public_flat_rw*/;
		reg [15:0] srom [0:131071] /*verilator public_flat_rw*/;
		reg [15:0] drom [0:1048575] /*verilator public_flat_rw*/;
		reg [7:0]  arom [0:262143] /*verilator public_flat_rw*/;     // the sound ROM
		reg [15:0] vrom [0:1048575] /*verilator public_flat_rw*/;    // the C140's voices (the region's words)
		reg [7:0]  irom [0:32767]  /*verilator public_flat_rw*/;     // the MCU's ROM: the C65's internal (8 KB) or c68.bin
		reg [7:0]  erom [0:32767]  /*verilator public_flat_rw*/;     // its EPROM
		reg [15:0] mrq_r, srq_r, drq_r;
		reg [7:0]  arq_r, irq_r, erq_r;
		always @(posedge clk) begin
			mrq_r <= mrom[mra]; srq_r <= srom[sra]; drq_r <= drom[dra];
			arq_r <= arom[ara]; irq_r <= irom[mcu_c68 ? ira68 : {2'b00, ira}]; erq_r <= erom[era];
			vr_valid <= vr_req; vr_q <= vrom[vr_addr];
		end
		assign {mrq, srq, drq, arq, irq_q, erq} = {mrq_r, srq_r, drq_r, arq_r, irq_r, erq_r};
		// dbg_stall (simulation): the master's ROM as a cache that misses
		assign {m_ready, s_ready, d_ready, a_ready, mcu_ready} = {!dbg_stall, 4'b1111};
		assign {mprog_req, sprog_req, drom_req, aud_req, mcu_req, c140_req} = 6'd0;
		assign mprog_addr = 0; assign sprog_addr = 0; assign drom_addr = 0; assign aud_addr = 0; assign mcu_addr_m = 0; assign c140_addr = 0;
	end else begin : g_caches
		// the SDRAM words hold the image's even byte low; the 68000's ROMs and
		// the C140's region are big-endian words
		wire [15:0] mw, sw, dw, aw, uw;
		ns2_rom_cache #(.AW(17)) u_mc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(mra), .rd_in(m_rd), .data(mw), .ready(m_ready),
			.m_req(mprog_req), .m_addr(mprog_addr), .m_ack(mprog_ack), .m_valid(mprog_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(17)) u_sc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(sra), .rd_in(s_rd), .data(sw), .ready(s_ready),
			.m_req(sprog_req), .m_addr(sprog_addr), .m_ack(sprog_ack), .m_valid(sprog_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(20)) u_dc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(dra), .rd_in(d_rd), .data(dw), .ready(d_ready),
			.m_req(drom_req), .m_addr(drom_addr), .m_ack(drom_ack), .m_valid(drom_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(17), .SAMPLED(1)) u_ac (.clk(clk), .rst(reset), .smp(a_smp), .addr_in(ara[17:1]), .rd_in(a_rd), .data(aw), .ready(a_ready),
			.m_req(aud_req), .m_addr(aud_addr), .m_ack(aud_ack), .m_valid(aud_valid), .m_data(bank0_data));
		// the MCU's 64 KB: its EPROM (the C65's 8000-ffff), then its internal
		// ROM (the C65's 0000-1fff, the C68's c68.bin at 8000-ffff)
		wire [15:0] ub = mcu_c68 ? {1'b1, mcu_a[14:0]} : mcu_a[15] ? {1'b0, mcu_a[14:0]} : {3'b100, mcu_a[12:0]};
		ns2_rom_cache #(.AW(15), .SAMPLED(1)) u_uc (.clk(clk), .rst(reset), .smp(mcu_smp), .addr_in(ub[15:1]), .rd_in(mcu_rd), .data(uw), .ready(mcu_ready),
			.m_req(mcu_req), .m_addr(mcu_addr_m), .m_ack(mcu_ack), .m_valid(mcu_valid), .m_data(bank0_data));
		assign mrq = {mw[7:0], mw[15:8]};
		assign srq = {sw[7:0], sw[15:8]};
		assign drq = {dw[7:0], dw[15:8]};
		// the byte of the word: the live address (the caches are ready only
		// while their word is the live one)
		assign arq = ara[0] ? aw[15:8] : aw[7:0];
		assign irq_q = ub[0] ? uw[15:8] : uw[7:0];
		assign erq = irq_q;
		// the C140: its request held until the bank takes it; the word of the burst
		reg        c_req;
		reg [17:0] c_addr;
		reg [1:0]  c_w;
		always @(posedge clk) begin
			vr_valid <= 1'b0;
			if (reset) c_req <= 1'b0;
			else begin
				if (vr_req) begin c_req <= 1'b1; c_addr <= vr_addr[19:2]; c_w <= vr_addr[1:0]; end
				if (c_req && c140_ack) c_req <= 1'b0;
				if (c140_valid) begin
					vr_valid <= 1'b1;
					vr_q <= {bank1_data[16 * c_w +: 8], bank1_data[16 * c_w + 8 +: 8]};
				end
			end
		end
		assign c140_req = c_req;
		assign c140_addr = c_addr;
	end endgenerate

	// line events
	wire       line_start = ce_pix && hcnt == 9'd383;     // the next clock starts a line
	reg        ev_vbl, ev_pos, ev_mcu;
	wire       pos_here;
	reg  [8:0] vnext;
	always @(posedge clk) begin
		ev_vbl <= 1'b0; ev_pos <= 1'b0; ev_mcu <= 1'b0;
		if (line_start) vnext <= vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
		// one clock after the counters moved to the new line
		if (ce_pix && hcnt == 9'd0) begin
			ev_vbl <= vcnt == 9'd240;
			ev_mcu <= vcnt == 9'd200;
			ev_pos <= pos_here;
		end
	end

	// the DPRAM: three users (68000s, sound, MCU) on a true dual port RAM.
	// Port A is the 68000s'. Port B alternates clocks between the sound CPU
	// and the MCU: each holds its address for a whole bus cycle (dozens of
	// clocks), so its read is at most three clocks old, and its write (a
	// one-clock pulse) waits for its turn, at most a clock.
	reg  [7:0] dpram [0:2047] /*verilator public_flat_rw*/;
	wire [10:0] dpa_m, dpa_s, dpa_u;
	wire [7:0]  dpd_m, dpd_s, dpd_u;
	wire        dpw_m, dpw_s, dpw_u;
	reg  [7:0]  dpq_m, dpq_s, dpq_u;
	always @(posedge clk)
		if (dpw_m) begin dpram[dpa_m] <= dpd_m; dpq_m <= dpd_m; end
		else dpq_m <= dpram[dpa_m];
	reg         dp_t, dp_td;                // port B's turn: 0 sound, 1 MCU (and last clock's)
	reg         pw_s, pw_u;                 // a write waiting for its turn
	reg  [10:0] pa_s, pa_u;
	reg  [7:0]  pd_s, pd_u, dpq_b;
	wire        b_we = dp_t ? pw_u : pw_s;
	wire [10:0] b_a  = dp_t ? (pw_u ? pa_u : dpa_u) : (pw_s ? pa_s : dpa_s);
	wire [7:0]  b_d  = dp_t ? pd_u : pd_s;
	always @(posedge clk)
		if (b_we) begin dpram[b_a] <= b_d; dpq_b <= b_d; end
		else dpq_b <= dpram[b_a];
	always @(posedge clk) begin
		dp_t <= ~dp_t; dp_td <= dp_t;
		if (b_we && dp_t) pw_u <= 1'b0;
		if (b_we && !dp_t) pw_s <= 1'b0;
		if (dpw_s) begin pw_s <= 1'b1; pa_s <= dpa_s; pd_s <= dpd_s; end
		if (dpw_u) begin pw_u <= 1'b1; pa_u <= dpa_u; pd_u <= dpd_u; end
		if (dp_td) dpq_u <= dpq_b; else dpq_s <= dpq_b;
		if (reset) begin pw_s <= 1'b0; pw_u <= 1'b0; end
	end

	// the 68000s
	wire [20:1] v_addr;
	wire [15:0] v_dout, v_din;
	wire        v_rnw, v_uds, v_lds, cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl;
	wire        cs_c169, cs_c169ctl, cs_c355, cs_c355pos;
	// the RAMs in the SDRAM (WRAM_SD): ns2_mem's clients, or (ROMS = 0) a
	// model of them, a burst eight clocks after its request
	wire [2:0]  wm_req, wm_we, wm_ack, wm_valid;
	wire [44:0] wm_addr;
	wire [47:0] wm_din;
	wire [5:0]  wm_dsn;
	wire [63:0] wm_data;
	generate if (WRAM_SD && ROMS == 0) begin : g_wram_model
		reg [15:0] wram [0:98303] /*verilator public_flat_rw*/;
		reg [2:0]  ack, val;
		reg [63:0] q;
		reg        busy;
		reg [1:0]  who;
		reg [16:0] line;
		reg [3:0]  cnt;
		integer    i;
		initial for (i = 0; i < 98304; i = i + 1) wram[i] = 16'h0000;
		wire [2:0] rq = wm_req & ~ack;
		wire [1:0] pick = rq[0] ? 2'd0 : rq[1] ? 2'd1 : 2'd2;
		wire [16:0] w_a = {pick, wm_addr[15 * pick +: 15]};
		wire [15:0] w_d = wm_din[16 * pick +: 16];
		wire [1:0]  w_m = wm_dsn[2 * pick +: 2];
		always @(posedge clk) begin
			ack <= 0; val <= 0;
			if (reset) busy <= 1'b0;
			else if (busy) begin
				cnt <= cnt - 1'd1;
				if (cnt == 0) begin
					busy <= 1'b0; val[who] <= 1'b1;
					q <= {wram[line + 3], wram[line + 2], wram[line + 1], wram[line]};
				end
			end else if (|rq) begin
				ack[pick] <= 1'b1;
				if (wm_we[pick]) begin
					if (!w_m[1]) wram[w_a][15:8] <= w_d[15:8];
					if (!w_m[0]) wram[w_a][7:0]  <= w_d[7:0];
				end else begin busy <= 1'b1; who <= pick; line <= w_a; cnt <= 4'd7; end
			end
		end
		assign wm_ack = ack; assign wm_valid = val; assign wm_data = q;
		assign {wram_req, wram_we, wram_addr, wram_din, wram_dsn} = 0;
	end else begin : g_wram_mem
		assign {wram_req, wram_we, wram_addr, wram_din, wram_dsn} = {wm_req, wm_we, wm_addr, wm_din, wm_dsn};
		assign wm_ack = wram_ack; assign wm_valid = wram_valid; assign wm_data = bank1_data;
	end endgenerate

	ns2_main #(.WRAM_SD(WRAM_SD)) u_main (
		.clk(clk), .reset(reset), .board(board), .key_table(key_table), .key_mode(key_mode),
		.wm_req(wm_req), .wm_we(wm_we), .wm_addr(wm_addr), .wm_din(wm_din), .wm_dsn(wm_dsn),
		.wm_ack(wm_ack), .wm_valid(wm_valid), .wm_data(wm_data),
		.mrom_addr(mra), .mrom_data(mrq), .mrom_ready(m_ready), .mrom_rd(m_rd),
		.srom_addr(sra), .srom_data(srq), .srom_ready(s_ready), .srom_rd(s_rd),
		.drom_addr(dra), .drom_data(drq), .drom_ready(d_ready), .drom_rd(d_rd),
		.nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data), .nv_q(nv_q), .nv_cpu_we(nv_cpu_we), .cpu_hold(hold_main), .stop(cpu_stop),
		.vblank(ev_vbl), .posirq(ev_pos), .sound_run(sound_run), .sub_run(sub_run),
		.v_addr(v_addr), .v_dout(v_dout), .v_rnw(v_rnw), .v_uds(v_uds), .v_lds(v_lds),
		.cs_tmap(cs_tmap), .cs_tctl(cs_tctl), .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_gfx(cs_gfx),
		.cs_roz(cs_roz), .cs_rozctl(cs_rozctl), .cs_c169(cs_c169), .cs_c169ctl(cs_c169ctl), .cs_c355(cs_c355), .cs_c355pos(cs_c355pos),
		.v_din(v_din),
		.dp_addr(dpa_m), .dp_dout(dpd_m), .dp_we(dpw_m), .dp_din(dpq_m),
		.m_as(m_as), .s_as(s_as), .m_addr(m_addr), .s_addr(s_addr), .m_rnw(m_rnw), .s_rnw(s_rnw),
		.m_wdata(m_wdata), .s_wdata(s_wdata), .m_ds(m_ds), .s_ds(s_ds),
		.m_rdata(m_rdata), .s_rdata(s_rdata), .m_dtack(m_dtack), .s_dtack(s_dtack));

	// the video
	ns2_video #(.HAS_SPRA(HAS_SPRA), .HAS_ROZ(HAS_ROZ), .HAS_C45(HAS_C45), .HAS_C169(HAS_C169), .HAS_C355(HAS_C355)) u_video (
		.clk(clk), .reset(reset), .board(board), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.dl_clut_we(clut_we), .dl_clut_addr(clut_addr), .dl_clut_data(clut_data),
		.hcnt(hcnt), .vcnt(vcnt), .ce_pix(ce_pix), .hblank(), .vblank(), .hsync(), .vsync(),
		.red(red), .green(green), .blue(blue), .out_x(out_x), .out_y(out_y), .out_valid(out_valid),
		.posirq_line(pos_here),
		.cpu_addr(v_addr), .cpu_dout(v_dout), .cpu_rnw(v_rnw), .cpu_uds(v_uds), .cpu_lds(v_lds),
		.cs_tmap(cs_tmap), .cs_tctl(cs_tctl), .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_gfx(cs_gfx),
		.cs_roz(cs_roz), .cs_rozctl(cs_rozctl), .cs_c169ctl(cs_c169ctl), .cs_c169(cs_c169), .cs_c355(cs_c355), .cs_c355pos(cs_c355pos),
		.cpu_din(v_din),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.overrun(overrun), .overrun_src(overrun_src), .line_busy_max(line_busy_max));

	// the I/O MCU: the C65 or the C68
	wire [10:0] dpa_65, dpa_68;
	wire [7:0]  dpd_65, dpd_68;
	wire        dpw_65, dpw_68;
	wire        w_65, w_68;
	wire [7:0]  d_65, d_68;
	wire        rd_65, rd_68;
	assign mcu_rd = mcu_c68 ? rd_68 : rd_65;
	ns2_c65 u_mcu (
		.clk(clk), .por(reset), .reset(reset || !sub_run || mcu_c68), .irq_line200(ev_mcu), .rom_ready(mcu_ready), .rom_rd(rd_65), .rom_smp(smp_65), .rom_hold(hold_65), .stop(cpu_stop),
		.irom_addr(ira), .irom_data(irq_q), .erom_addr(era), .erom_data(erq),
		.dp_addr(dpa_65), .dp_dout(dpd_65), .dp_we(dpw_65), .dp_din(dpq_u),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_addr(a_65), .dbg_wr(w_65), .dbg_dout(d_65));
	ns2_c68 u_c68 (
		.clk(clk), .reset(reset || !sub_run || !mcu_c68), .irq_line200(ev_mcu), .rom_ready(mcu_ready), .rom_rd(rd_68), .rom_smp(smp_68), .rom_hold(hold_68), .stop(cpu_stop),
		.rom_addr(ira68), .rom_data(irq_q),
		.dp_addr(dpa_68), .dp_dout(dpd_68), .dp_we(dpw_68), .dp_din(dpq_u),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_addr(a_68), .dbg_wr(w_68), .dbg_dout(d_68), .dbg_tap(mcu_tap), .dbg_sync(mcu_sync), .dbg_cen(mcu_cen), .dbg_din(mcu_din));
	assign dpa_u = mcu_c68 ? dpa_68 : dpa_65;
	assign dpd_u = mcu_c68 ? dpd_68 : dpd_65;
	assign dpw_u = mcu_c68 ? dpw_68 : dpw_65;
	assign mcu_addr = mcu_c68 ? a_68 : a_65;
	assign mcu_wr   = mcu_c68 ? w_68 : w_65;
	assign mcu_dout = mcu_c68 ? d_68 : d_65;

	// the sound board
	ns2_sound #(.C140_MAME_RATE(C140_MAME_RATE)) u_sound (
		.clk(clk), .reset(reset), .run(sound_run),
		.rom_addr(ara), .rom_data(arq), .rom_ready(a_ready), .rom_rd(a_rd), .rom_smp(a_smp), .rom_hold(hold_snd), .stop(cpu_stop),
		.dp_addr(dpa_s), .dp_dout(dpd_s), .dp_we(dpw_s), .dp_din(dpq_s),
		.ym_left(ym_left), .ym_right(ym_right), .ym_sample(),
		.vrom_req(vr_req), .vrom_addr(vr_addr), .vrom_valid(vr_valid), .vrom_data(vr_q),
		.c140_left(c140_left), .c140_right(c140_right), .c140_raw_l(c140_raw_l), .c140_raw_r(c140_raw_r),
		.c140_sample(c140_sample),
		.dbg_addr(snd_addr), .dbg_wr(snd_wr), .dbg_dout(snd_dout));

endmodule
