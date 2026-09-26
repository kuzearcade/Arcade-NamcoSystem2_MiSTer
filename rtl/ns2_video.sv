// Namco System 2 video, the standard board (docs/PLAN.md M1):
//   C123 tilemaps, C116 palette / clip / raster registers, sprites (A), ROZ (A).
// The mix follows namcos2_state::screen_update (tools/ns2_model.py render):
//   planes and ROZ by priority 0..7 (ROZ after the planes of its priority),
//   then the sprites where their priority >= the pixel's, pen 0xffe a shadow
//   (+0x800 over a tilemap/ROZ colour of the upper palette half, else black),
//   everything outside the C116 window black. An empty pixel is black, the
//   palette's own black entry, not pen 0 (NS2-2).
//
// Each line is rendered during the line before it into double-buffered line
// buffers (tilemap composition, ROZ, sprites), which the display side reads
// and clears. clk is clk_sys (49.152 MHz); a pixel is 8 clocks.
module ns2_video #(
	// the bitstream's blocks: a board whose block is left out shows without
	// it (the standard bitstream has neither; docs/PLAN.md Appendix F)
	parameter HAS_C45  = 1,
	parameter HAS_C169 = 1,
	parameter HAS_C355 = 1
) (
	input             clk,
	input             reset,
	// the board: 0 standard (ROZ A, sprites A), 1 Final Lap (C45 road,
	// sprites A with 4-bit priority, priorities 0..15), 2 Metal Hawk (C169
	// and its sprites, priorities 0..15), 3 Steel Gunner (C355 sprites,
	// priorities 0..7), 4 Suzuka 8 Hours (C45 road, C355, 0..15), 5 Lucky &
	// Wild (C45, C169, C355, 0..15)
	input      [2:0]  board,
	input             tile_fl2,     // finalap2 / finalap3 tile callback
	input             spr_fl,       // finallap: namcos2_sprite_finallap_device
	input             dl_clut_we,   // the download: the C45 road CLUT
	input      [7:0]  dl_clut_addr,
	input      [7:0]  dl_clut_data,
	// raster
	output reg [8:0]  hcnt,
	output reg [8:0]  vcnt,
	output            ce_pix,
	output reg        hblank,
	output reg        vblank,
	output reg        hsync,
	output reg        vsync,
	output reg [7:0]  red,
	output reg [7:0]  green,
	output reg [7:0]  blue,
	// the pixel on red/green/blue (for the testbenches)
	output reg [8:0]  out_x,
	output reg [7:0]  out_y,
	output reg        out_valid,
	output            posirq_line,  // this line is the C116's POSIRQ line
	// CPU (68000 word bus; byte strobes). Reads return one clock later.
	input      [20:1] cpu_addr,     // within the selected device
	input      [15:0] cpu_dout,
	input             cpu_rnw,
	input             cpu_uds,
	input             cpu_lds,
	input             cs_tmap,      // 400000-40ffff
	input             cs_tctl,      // 420000-42003f
	input             cs_pal,       // 440000-44ffff
	input             cs_spr,       // c00000-c03fff
	input             cs_gfx,       // c40000 (gfx_ctrl)
	input             cs_roz,       // c80000-c9ffff
	input             cs_rozctl,    // cc0000-cc000f
	input             cs_c169ctl,   // d00000-d0001f (Metal Hawk, Lucky & Wild)
	input             cs_c169,      // c40000-c4ffff / c00000-c0ffff: the C169 RAM
	input             cs_c355,      // 800000-8141ff: the C355 RAM
	input             cs_c355pos,   // 900000-900007: its position registers
	output reg [15:0] cpu_din,
	// graphics ROMs: 64-bit bursts (byte n of a burst at [8n +: 8]); a request
	// holds until ack; data returns in request order with valid
	output            tile_req,
	output     [18:0] tile_addr,
	input             tile_ack,
	input             tile_valid,
	input      [63:0] tile_data,
	output            tmask_req,
	output     [18:0] tmask_addr,   // byte address
	input             tmask_ack,
	input             tmask_valid,
	input      [7:0]  tmask_data,
	output            roz_req,
	output     [18:0] roz_addr,
	input             roz_ack,
	input             roz_valid,
	input      [63:0] roz_data,
	output            c169_req,
	output     [20:0] c169_addr,
	input             c169_ack,
	input             c169_valid,
	input      [63:0] c169_data,
	output            c169m_req,
	output     [18:0] c169m_addr,   // byte address
	input             c169m_ack,
	input             c169m_valid,
	input      [7:0]  c169m_data,
	output            spr_req,
	output     [19:0] spr_addr,     // bit 19: Metal Hawk's rot90 (the transposed copy)
	input             spr_ack,
	input             spr_valid,
	input      [63:0] spr_data,
	// a line was not rendered in time (the testbenches fail on it), and which
	// renderers were still busy: {c355, sprites A, C169, road, ROZ, C123}
	output reg        overrun,
	output reg [5:0]  overrun_src,
	output reg [11:0] line_busy_max   // the most clocks a line kept the renderers busy (of 3072)
);
	// ------------------------------------------------------------ raster
	reg [2:0] div;
	assign ce_pix = div == 3'd7;
	always @(posedge clk) begin
		// MAME's screen starts at the top of VBLANK (vpos 224)
		if (reset) begin div <= 0; hcnt <= 0; vcnt <= 9'd224; end
		else begin
			div <= div + 1'd1;
			if (ce_pix) begin
				if (hcnt == 9'd383) begin
					hcnt <= 0;
					vcnt <= vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
				end else hcnt <= hcnt + 1'd1;
				hblank <= hcnt >= 9'd287 && hcnt != 9'd383;
				vblank <= vcnt >= 9'd224;
				// sync positions are settled against the board in M3
				hsync  <= hcnt >= 9'd320 && hcnt < 9'd352;
				vsync  <= vcnt >= 9'd240 && vcnt < 9'd243;
			end
		end
	end

	// ------------------------------------------------------------ registers
	reg [15:0] tctl [0:31] /*verilator public_flat_rw*/;
	reg [15:0] c116 [0:7]  /*verilator public_flat_rw*/;
	reg [15:0] gfx_ctrl    /*verilator public_flat_rw*/;
	reg [15:0] rozctl [0:7] /*verilator public_flat_rw*/;
	reg [15:0] c169ctl [0:15] /*verilator public_flat_rw*/;
	reg [15:0] c355pos [0:3] /*verilator public_flat_rw*/;
	wire [255:0] c169ctl_flat;
	wire [511:0] tctl_flat;
	wire [127:0] rozctl_flat;
	genvar gi;
	generate
		for (gi = 0; gi < 32; gi = gi + 1) begin : g_tctl
			assign tctl_flat[16 * gi +: 16] = tctl[gi];
		end
		for (gi = 0; gi < 8; gi = gi + 1) begin : g_rozctl
			assign rozctl_flat[16 * gi +: 16] = rozctl[gi];
		end
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_c169ctl
			assign c169ctl_flat[16 * gi +: 16] = c169ctl[gi];
		end
	endgenerate
	// MAME's POSIRQ line: (C116 register 5 - 32) & 0xff (namcos2 get_pos_irq_scanline)
	wire [7:0] pos_line = c116[5][7:0] - 8'd32;
	assign posirq_line = vcnt[7:0] == pos_line && vcnt < 9'd256;

	// ------------------------------------------------------------ RAMs
	// two ports each: the CPU's and the video's (Intel's true dual port
	// template in 8-bit lanes, docs/PLAN.md Appendix F)
	reg [7:0]  tmap_h [0:32767] /*verilator public_flat_rw*/, tmap_l [0:32767] /*verilator public_flat_rw*/;
	reg [7:0]  spr_h  [0:8191]  /*verilator public_flat_rw*/, spr_l  [0:8191]  /*verilator public_flat_rw*/;
	reg [7:0]  roz_h  [0:65535] /*verilator public_flat_rw*/, roz_l  [0:65535] /*verilator public_flat_rw*/;
	reg [7:0]  clut   [0:255]   /*verilator public_flat_rw*/;   // C45 road CLUT (ROM, from the download)
	always @(posedge clk) if (HAS_C45 && dl_clut_we) clut[dl_clut_addr] <= dl_clut_data;
	reg [7:0]  c169_h [0:32767] /*verilator public_flat_rw*/, c169_l [0:32767] /*verilator public_flat_rw*/;
	reg [7:0]  c355_h [0:41215] /*verilator public_flat_rw*/, c355_l [0:41215] /*verilator public_flat_rw*/;  // 0xa100 words
	reg [7:0]  pal_r  [0:8191]  /*verilator public_flat_rw*/, pal_g  [0:8191]  /*verilator public_flat_rw*/,
	           pal_b  [0:8191]  /*verilator public_flat_rw*/;

	wire cw = !cpu_rnw;
	reg [15:0] tmap_q, spr_q, roz_q, c169_q, c355_q;   // (combinational)
	reg [7:0]  pal_rq, pal_gq, pal_bq, pal_reg;
	reg [1:0]  pal_sel;
	wire [7:0] pal_q = pal_sel == 2'd0 ? pal_rq : pal_sel == 2'd1 ? pal_gq : pal_sel == 2'd2 ? pal_bq : pal_reg;
	reg [2:0]  rsel;
	// the C116's space: word o, plane (o >> 11) & 3 (R, G, B, registers),
	// colour ((o & 0x6000) >> 2) | (o & 0x7ff); the low byte is the data
	wire [14:0] po     = cpu_addr[15:1];
	wire [1:0]  pplane = po[12:11];
	wire [12:0] pcol   = {po[14:13], po[10:0]};
	// the CPU's port of each lane, in Intel's true dual port template: a write
	// returns its own data (the CPU takes no data from a write), so the video's
	// port is the RAM's second port and nothing is duplicated
	reg [7:0]  tq_h, tq_l, sq_h, sq_l, rq_h, rq_l, kq_h, kq_l, cq_h, cq_l;
	always @(*) begin
		tmap_q = {tq_h, tq_l}; spr_q = {sq_h, sq_l}; roz_q = {rq_h, rq_l};
		c169_q = {kq_h, kq_l}; c355_q = {cq_h, cq_l};
	end
	wire cw_h = cw && cpu_uds, cw_l = cw && cpu_lds;
	wire c355_in = cs_c355 && cpu_addr[16:1] < 17'h0a100;
	always @(posedge clk)
		if (cs_tmap && cw_h) begin tmap_h[cpu_addr[15:1]] <= cpu_dout[15:8]; tq_h <= cpu_dout[15:8]; end
		else tq_h <= tmap_h[cpu_addr[15:1]];
	always @(posedge clk)
		if (cs_tmap && cw_l) begin tmap_l[cpu_addr[15:1]] <= cpu_dout[7:0]; tq_l <= cpu_dout[7:0]; end
		else tq_l <= tmap_l[cpu_addr[15:1]];
	always @(posedge clk)
		if (cs_spr && cw_h) begin spr_h[cpu_addr[13:1]] <= cpu_dout[15:8]; sq_h <= cpu_dout[15:8]; end
		else sq_h <= spr_h[cpu_addr[13:1]];
	always @(posedge clk)
		if (cs_spr && cw_l) begin spr_l[cpu_addr[13:1]] <= cpu_dout[7:0]; sq_l <= cpu_dout[7:0]; end
		else sq_l <= spr_l[cpu_addr[13:1]];
	always @(posedge clk)
		if (cs_roz && cw_h) begin roz_h[cpu_addr[16:1]] <= cpu_dout[15:8]; rq_h <= cpu_dout[15:8]; end
		else rq_h <= roz_h[cpu_addr[16:1]];
	always @(posedge clk)
		if (cs_roz && cw_l) begin roz_l[cpu_addr[16:1]] <= cpu_dout[7:0]; rq_l <= cpu_dout[7:0]; end
		else rq_l <= roz_l[cpu_addr[16:1]];
	always @(posedge clk)
		if (HAS_C169 && cs_c169 && cw_h) begin c169_h[cpu_addr[15:1]] <= cpu_dout[15:8]; kq_h <= cpu_dout[15:8]; end
		else if (HAS_C169) kq_h <= c169_h[cpu_addr[15:1]];
	always @(posedge clk)
		if (HAS_C169 && cs_c169 && cw_l) begin c169_l[cpu_addr[15:1]] <= cpu_dout[7:0]; kq_l <= cpu_dout[7:0]; end
		else if (HAS_C169) kq_l <= c169_l[cpu_addr[15:1]];
	always @(posedge clk)
		if (HAS_C355 && c355_in && cw_h) begin c355_h[cpu_addr[16:1]] <= cpu_dout[15:8]; cq_h <= cpu_dout[15:8]; end
		else if (HAS_C355) cq_h <= c355_h[cpu_addr[16:1]];
	always @(posedge clk)
		if (HAS_C355 && c355_in && cw_l) begin c355_l[cpu_addr[16:1]] <= cpu_dout[7:0]; cq_l <= cpu_dout[7:0]; end
		else if (HAS_C355) cq_l <= c355_l[cpu_addr[16:1]];
	// the C116 sits on D7-D0 and takes any byte of the word (MAME's
	// umask16(0x00ff).cswidth(16)): a byte write to the even address (UDS
	// alone) writes too, with the byte the 68000 puts on both lanes
	wire pal_w = cs_pal && cw && (cpu_uds || cpu_lds);
	always @(posedge clk)
		if (pal_w && pplane == 2'd0) begin pal_r[pcol] <= cpu_dout[7:0]; pal_rq <= cpu_dout[7:0]; end
		else pal_rq <= pal_r[pcol];
	always @(posedge clk)
		if (pal_w && pplane == 2'd1) begin pal_g[pcol] <= cpu_dout[7:0]; pal_gq <= cpu_dout[7:0]; end
		else pal_gq <= pal_g[pcol];
	always @(posedge clk)
		if (pal_w && pplane == 2'd2) begin pal_b[pcol] <= cpu_dout[7:0]; pal_bq <= cpu_dout[7:0]; end
		else pal_bq <= pal_b[pcol];
	always @(posedge clk) begin
		if (cs_c355pos && cw) begin
			if (cpu_uds) c355pos[cpu_addr[2:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) c355pos[cpu_addr[2:1]][7:0]  <= cpu_dout[7:0];
		end
		if (cs_pal) begin
			if (cw && (cpu_uds || cpu_lds) && pplane == 2'd3) begin
				if (po[0]) c116[po[3:1]][7:0] <= cpu_dout[7:0];
				else       c116[po[3:1]][15:8] <= cpu_dout[7:0];
			end
			pal_sel <= pplane;
			// registers 6 and 7 read 0xff (namcos2_base_state::c116_r, MAME's
			// "fix for finallap boot")
			pal_reg <= po[3:0] > 4'hb ? 8'hff : po[0] ? c116[po[3:1]][7:0] : c116[po[3:1]][15:8];
		end
		if (cs_tctl && cw) begin
			if (cpu_uds) tctl[cpu_addr[5:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) tctl[cpu_addr[5:1]][7:0]  <= cpu_dout[7:0];
		end
		if (cs_gfx && cw) begin
			if (cpu_uds) gfx_ctrl[15:8] <= cpu_dout[15:8];
			if (cpu_lds) gfx_ctrl[7:0]  <= cpu_dout[7:0];
		end
		if (cs_c169ctl && cw) begin
			if (cpu_uds) c169ctl[cpu_addr[4:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) c169ctl[cpu_addr[4:1]][7:0]  <= cpu_dout[7:0];
		end
		if (cs_rozctl && cw) begin
			if (cpu_uds) rozctl[cpu_addr[3:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) rozctl[cpu_addr[3:1]][7:0]  <= cpu_dout[7:0];
		end
		rsel <= cs_tmap ? 3'd0 : cs_spr ? 3'd1 : cs_roz ? 3'd2 : cs_pal ? 3'd3 :
		        cs_c169 ? 3'd4 : cs_c355 ? 3'd5 : 3'd6;
	end
	reg [15:0] reg_q;
	always @(posedge clk) reg_q <= cs_tctl ? tctl[cpu_addr[5:1]] : cs_gfx ? gfx_ctrl :
	                               cs_c169ctl ? c169ctl[cpu_addr[4:1]] : cs_c355pos ? c355pos[cpu_addr[2:1]] :
	                               rozctl[cpu_addr[3:1]];
	always @(*) case (rsel)
		3'd0: cpu_din = tmap_q;
		3'd1: cpu_din = spr_q;
		3'd2: cpu_din = roz_q;
		3'd3: cpu_din = {8'h00, pal_q};      // MAME's umask16 reads fill the other lane with 0
		3'd4: cpu_din = c169_q;
		3'd5: cpu_din = c355_q;
		default: cpu_din = reg_q;
	endcase

	// video ports (the ROZ RAM is the road RAM on Final Lap)
	wire        fl = board == 3'd1;
	wire        mh = board == 3'd2;
	wire        sg = board == 3'd3;
	wire        road_b = HAS_C45 && (fl || board == 3'd4 || board == 3'd5);   // the C45 road
	wire        c169_b = HAS_C169 && (mh || board == 3'd5);                      // the C169
	wire        c355_b = HAS_C355 && board >= 3'd3;                              // the C355
	wire        lw = board == 3'd5;
	wire [14:0] vt_addr;
	wire [12:0] vs_addr;
	wire [15:0] vr_addr_roz, vr_addr_road;
	wire [14:0] vr_addr_c169;
	wire [15:0] vr_addr = road_b ? vr_addr_road : vr_addr_roz;
	wire [15:0] vc_addr;
	wire [7:0]  clut_addr;
	reg  [15:0] vt_q, vs_q, vr_q, v169_q, vc_raw;
	reg         vc_in;
	wire [15:0] vc_q = vc_in ? vc_raw : 16'h0000;
	reg  [7:0]  clut_q;
	// (a bitstream without a block has no reads of its RAMs: they go)
	always @(posedge clk) vt_q[15:8] <= tmap_h[vt_addr];
	always @(posedge clk) vt_q[7:0]  <= tmap_l[vt_addr];
	always @(posedge clk) vs_q[15:8] <= spr_h[vs_addr];
	always @(posedge clk) vs_q[7:0]  <= spr_l[vs_addr];
	always @(posedge clk) vr_q[15:8] <= roz_h[vr_addr];
	always @(posedge clk) vr_q[7:0]  <= roz_l[vr_addr];
	always @(posedge clk) if (HAS_C169) v169_q[15:8] <= c169_h[vr_addr_c169];
	always @(posedge clk) if (HAS_C169) v169_q[7:0]  <= c169_l[vr_addr_c169];
	always @(posedge clk) if (HAS_C355) vc_raw[15:8] <= c355_h[vc_addr];
	always @(posedge clk) if (HAS_C355) vc_raw[7:0]  <= c355_l[vc_addr];
	always @(posedge clk) vc_in <= vc_addr < 16'ha100;
	always @(posedge clk) if (HAS_C45) clut_q <= clut[clut_addr];

	// ------------------------------------------------------------ line sequencing
	// at the start of display line v, render line v + 1 (line 0 during 263)
	wire [8:0] vnext = vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
	reg        go;
	reg  [7:0] ry;
	reg [11:0] busy_cnt;
	initial begin line_busy_max = 0; overrun_src = 0; end
	wire       c123_busy, roz_busy, road_busy_i, c169_busy_i, spr_busy_a, c355_busy_i;
	// a block the bitstream leaves out has no outputs that are used (it goes)
	wire       road_busy = HAS_C45 && road_busy_i, c169_busy = HAS_C169 && c169_busy_i, c355_busy = HAS_C355 && c355_busy_i;
	wire       c169_req_i, c169m_req_i;
	wire [20:0] c169_addr_i;
	wire [18:0] c169m_addr_i;
	assign c169_req = HAS_C169 && c169_req_i;
	assign c169m_req = HAS_C169 && c169m_req_i;
	assign c169_addr = HAS_C169 ? c169_addr_i : 21'd0;
	assign c169m_addr = HAS_C169 ? c169m_addr_i : 19'd0;
	wire       spr_busy = spr_busy_a || c355_busy;
	always @(posedge clk) begin
		go <= 1'b0;
		overrun <= 1'b0;
		if (!reset && ce_pix && hcnt == 9'd0 && vnext < 9'd224) begin
			if (c123_busy || roz_busy || road_busy || c169_busy || spr_busy) overrun <= 1'b1;
			overrun_src <= overrun_src | {c355_busy, spr_busy_a, c169_busy, road_busy, roz_busy, c123_busy};
			busy_cnt <= 0;
			go <= 1'b1; ry <= vnext[7:0];
		end else if (c123_busy || roz_busy || road_busy || c169_busy || spr_busy) begin
			busy_cnt <= busy_cnt + 1'd1;
			if (busy_cnt >= line_busy_max) line_busy_max <= busy_cnt + 1'd1;
		end
	end

	wire        c_we, r_we_roz, r_we_road, s_we, s_we2;
	wire [8:0]  s_x2;
	wire [16:0] s_d2;
	wire [8:0]  c_x, r_x_roz, r_x_road, s_x;
	wire [16:0] c_d;
	wire [8:0]  r_d_roz, r_d_road;
	wire [16:0] s_d;
	wire        r_we = road_b ? r_we_road : r_we_roz;
	wire [8:0]  r_x  = road_b ? r_x_road  : r_x_roz;
	wire [8:0]  r_d  = road_b ? r_d_road  : r_d_roz;
	wire        road_attr_we;
	wire [3:0]  road_pri;

	ns2_c123 u_c123 (
		.clk(clk), .reset(reset), .start(go), .y(ry), .busy(c123_busy), .ctl(tctl_flat), .tile_fl2(tile_fl2),
		.vr_addr(vt_addr), .vr_data(vt_q),
		.t_req(tile_req), .t_addr(tile_addr), .t_ack(tile_ack), .t_valid(tile_valid), .t_data(tile_data),
		.m_req(tmask_req), .m_addr(tmask_addr), .m_ack(tmask_ack), .m_valid(tmask_valid), .m_data(tmask_data),
		.lb_we(c_we), .lb_x(c_x), .lb_d(c_d));

	ns2_roz u_roz (
		.clk(clk), .reset(reset), .start(go && board == 3'd0), .y(ry), .busy(roz_busy), .ctl(rozctl_flat),
		.rr_addr(vr_addr_roz), .rr_data(vr_q),
		.r_req(roz_req), .r_addr(roz_addr), .r_ack(roz_ack), .r_valid(roz_valid), .r_data(roz_data),
		.lb_we(r_we_roz), .lb_x(r_x_roz), .lb_d(r_d_roz));

	wire        l_we, l_layer;
	wire [8:0]  l_x;
	wire [16:0] l_d;
	ns2_c169 u_c169 (
		.clk(clk), .reset(reset), .start(go && c169_b), .y(ry), .busy(c169_busy_i), .lw(lw), .ctl(c169ctl_flat),
		.vr_addr(vr_addr_c169), .vr_data(v169_q),
		.r_req(c169_req_i), .r_addr(c169_addr_i), .r_ack(c169_ack), .r_valid(c169_valid), .r_data(c169_data),
		.m_req(c169m_req_i), .m_addr(c169m_addr_i), .m_ack(c169m_ack), .m_valid(c169m_valid), .m_data(c169m_data),
		.lb_we(l_we), .lb_layer(l_layer), .lb_x(l_x), .lb_d(l_d));

	ns2_c45 u_road (
		.clk(clk), .reset(reset), .start(go && road_b), .y(ry), .busy(road_busy_i),
		.rd_addr(vr_addr_road), .rd_data(vr_q), .clut_addr(clut_addr), .clut_data(clut_q),
		.attr_we(road_attr_we), .attr_pri(road_pri),
		.lb_we(r_we_road), .lb_x(r_x_road), .lb_d(r_d_road));

	wire        sa_req, sc_req, sa_we, sc_we, sc_we2;
	wire [8:0]  sc_x2;
	wire [16:0] sc_d2;
	wire [19:0] sa_addr;
	wire [18:0] sc_addr;
	wire [8:0]  sa_x, sc_x;
	wire [16:0] sa_d, sc_d;
	ns2_sprite_a u_spr (
		.clk(clk), .reset(reset), .start(go && !c355_b), .y(ry), .busy(spr_busy_a), .gfx_ctrl(gfx_ctrl), .pri4(fl), .spr_fl(spr_fl), .mh(mh),
		.sr_addr(vs_addr), .sr_data(vs_q),
		.s_req(sa_req), .s_addr(sa_addr), .s_ack(spr_ack && !c355_b), .s_valid(spr_valid && !c355_b), .s_data(spr_data),
		.lb_we(sa_we), .lb_x(sa_x), .lb_d(sa_d));

	// the C355 builds its records in vblank, from line 225
	wire        prep = c355_b && ce_pix && hcnt == 9'd0 && vcnt == 9'd225;
	ns2_c355 u_c355 (
		.clk(clk), .reset(reset), .prep(prep), .start(go && c355_b), .y(ry), .busy(c355_busy_i),
		.pos0(c355pos[0]), .pos1(c355pos[1]),
		.cr_addr(vc_addr), .cr_data(vc_q),
		.s_req(sc_req), .s_addr(sc_addr), .s_ack(spr_ack && c355_b), .s_valid(spr_valid && c355_b), .s_data(spr_data),
		.lb_we(sc_we), .lb_x(sc_x), .lb_d(sc_d), .lb_we2(sc_we2), .lb_x2(sc_x2), .lb_d2(sc_d2));
	assign spr_req  = c355_b ? sc_req : sa_req;
	assign spr_addr = c355_b ? {1'b0, sc_addr} : sa_addr;
	assign s_we = c355_b ? sc_we : sa_we;
	assign s_x  = c355_b ? sc_x  : sa_x;
	assign s_d  = c355_b ? sc_d  : sa_d;
	assign s_we2 = c355_b && sc_we2;
	assign s_x2  = c355_b ? sc_x2 : 9'd0;
	assign s_d2  = c355_b ? sc_d2 : 17'd0;

	// the ROZ plane's (or the road line's) attributes, with its buffer:
	// {priority 0..15, colour bank}
	reg [7:0] roz_attr [0:1];
	always @(posedge clk) begin
		if (go && board == 3'd0) roz_attr[ry[0]] <= {1'b0, gfx_ctrl[14:12], gfx_ctrl[11:8]};
		if (HAS_C45 && road_attr_we) roz_attr[ry[0]] <= {road_pri, 4'hf};
	end

	// ------------------------------------------------------------ line buffers
	// {buffer = line & 1, x}; the renderers write the next line's, the display
	// reads the current line's and clears each pixel after reading it
	(* ramstyle = "no_rw_check" *) reg [16:0] lb_c [0:1023];
	(* ramstyle = "no_rw_check" *) reg [8:0]  lb_r [0:1023];
	// sprites: even and odd x in two arrays, two adjacent pixels a clock
	(* ramstyle = "no_rw_check" *) reg [16:0] lb_s0 [0:511];
	(* ramstyle = "no_rw_check" *) reg [16:0] lb_s1 [0:511];
	reg [16:0] qa, qb;
	reg [16:0] qc;
	reg [8:0]  qr;
	reg [16:0] qs0, qs1;
	wire [16:0] qs = hcnt[0] ? qs1 : qs0;
	wire       wb = ry[0];
	wire [9:0] da = {vcnt[0], hcnt};
	wire [8:0] ds = {vcnt[0], hcnt[8:1]};
	wire       dvis = vcnt < 9'd224 && hcnt < 9'd288;
	// each buffer is a true dual-port RAM: port A the renderer's writes (the
	// next line), port B the display's read every clock and its clear, a
	// clock after the read (div 2), of the current line
	wire       clr = div == 3'd2 && dvis;
	always @(posedge clk) if (c_we) lb_c[{wb, c_x}] <= c_d;
	always @(posedge clk) begin if (clr) lb_c[da] <= 17'd0; qc <= lb_c[da]; end
	always @(posedge clk) if (r_we) lb_r[{wb, r_x}] <= r_d;
	always @(posedge clk) begin if (clr) lb_r[da] <= 9'd0; qr <= lb_r[da]; end
	// sprites: two adjacent pixels a clock, one to each array
	wire       s0_we = (s_we && !s_x[0]) || (s_we2 && !s_x2[0]);
	wire [8:0] s0_a  = (s_we && !s_x[0]) ? {wb, s_x[8:1]} : {wb, s_x2[8:1]};
	wire [16:0] s0_d = (s_we && !s_x[0]) ? s_d : s_d2;
	wire       s1_we = (s_we && s_x[0]) || (s_we2 && s_x2[0]);
	wire [8:0] s1_a  = (s_we && s_x[0]) ? {wb, s_x[8:1]} : {wb, s_x2[8:1]};
	wire [16:0] s1_d = (s_we && s_x[0]) ? s_d : s_d2;
	always @(posedge clk) if (s0_we) lb_s0[s0_a] <= s0_d;
	always @(posedge clk) begin if (clr && !hcnt[0]) lb_s0[ds] <= 17'd0; qs0 <= lb_s0[ds]; end
	always @(posedge clk) if (s1_we) lb_s1[s1_a] <= s1_d;
	always @(posedge clk) begin if (clr && hcnt[0]) lb_s1[ds] <= 17'd0; qs1 <= lb_s1[ds]; end
	generate if (HAS_C169) begin : g_lb169
		(* ramstyle = "no_rw_check" *) reg [16:0] lb_a [0:1023];   // C169 layer 1
		(* ramstyle = "no_rw_check" *) reg [16:0] lb_b [0:1023];   // C169 layer 0
		always @(posedge clk) if (l_we && l_layer) lb_a[{wb, l_x}] <= l_d;
		always @(posedge clk) begin if (clr) lb_a[da] <= 17'd0; qa <= lb_a[da]; end
		always @(posedge clk) if (l_we && !l_layer) lb_b[{wb, l_x}] <= l_d;
		always @(posedge clk) begin if (clr) lb_b[da] <= 17'd0; qb <= lb_b[da]; end
	end else begin : g_nolb169
		always @(posedge clk) begin qa <= 17'd0; qb <= 17'd0; end
	end endgenerate

	// ------------------------------------------------------------ mix
	// div 0: address set (hcnt is this pixel); div 1: buffers read; div 2: mix;
	// div 4: palette read; div 5: out
	wire signed [10:0] x0 = $signed({2'b0, c116[0][8:0]}) - 11'sd74;
	wire signed [10:0] x1 = $signed({2'b0, c116[1][8:0]}) - 11'sd75;
	wire signed [10:0] y0 = $signed({2'b0, c116[2][8:0]}) - 11'sd33;
	wire signed [10:0] y1 = $signed({2'b0, c116[3][8:0]}) - 11'sd34;
	reg  [8:0]  mx;
	reg  [7:0]  my;
	reg         mvis, dest_v;
	reg  [12:0] dest;
	reg  [7:0]  pal_dr, pal_dg, pal_db;
	always @(posedge clk) pal_dr <= pal_r[dest];
	always @(posedge clk) pal_dg <= pal_g[dest];
	always @(posedge clk) pal_db <= pal_b[dest];
	reg         o_v, o_vis;
	reg  [8:0]  o_x;
	reg  [7:0]  o_y;
	wire        inclip = $signed({2'b0, mx}) >= x0 && $signed({2'b0, mx}) <= x1 &&
	                     $signed({3'b0, my}) >= y0 && $signed({3'b0, my}) <= y1;
	wire [7:0]  rattr  = roz_attr[my[0]];
	// priorities on the board's scale: standard 0..7 (ROZ after the planes
	// of its priority); the others 0..15 with plane p at 2p. At equal
	// priority MAME draws planes, then ROZ or road, then C169 layer 1, then
	// layer 0: the pixel shows the last drawn, the largest {priority, order}
	wire [3:0]  c_pv   = (board == 3'd0 || sg) ? {1'b0, qc[15:13]} : {qc[15:13], 1'b0};
	wire [3:0]  r_pv   = rattr[7:4];
	wire [5:0]  k_c    = qc[16] ? {c_pv, 2'd0} : 6'd0;
	wire [5:0]  k_r    = qr[8]  ? {r_pv, 2'd1} : 6'd0;
	wire [5:0]  k_a    = qa[16] ? {qa[15:12], 2'd2} : 6'd0;
	wire [5:0]  k_b    = qb[16] ? {qb[15:12], 2'd3} : 6'd0;
	wire [5:0]  k_cr   = k_r > k_c ? k_r : k_c;
	wire [5:0]  k_ab   = k_b > k_a ? k_b : k_a;
	wire [5:0]  k_w    = k_ab > k_cr ? k_ab : k_cr;
	wire        any    = qc[16] || qr[8] || qa[16] || qb[16];
	wire        b_v    = inclip && any;
	wire [12:0] b_col  = k_w[1:0] == 2'd3 ? {1'b0, qb[11:0]} : k_w[1:0] == 2'd2 ? {1'b0, qa[11:0]} :
	                     k_w[1:0] == 2'd1 ? {1'b0, rattr[3:0], qr[7:0]} : qc[12:0];
	wire [3:0]  b_pri  = b_v ? k_w[5:2] : 4'd0;
	// sprites
	wire        s_on   = qs[16] && inclip && b_pri <= qs[15:12];
	wire        shadow = qs[11:0] == 12'hffe;
	always @(posedge clk) begin
		if (div == 3'd1) begin mx <= hcnt; my <= vcnt[7:0]; mvis <= dvis; end
		if (div == 3'd2) begin
			if (s_on && !shadow)            begin dest_v <= 1'b1; dest <= {1'b0, qs[11:0]}; end
			// the shadow pen: +0x800 over the upper palette half, else black;
			// the C355's mix sets 0x800 whatever the colour
			else if (s_on && shadow)        begin dest_v <= b_v && (c355_b || b_col[12]); dest <= b_col | 13'h0800; end
			else                            begin dest_v <= b_v; dest <= b_col; end
			o_vis <= mvis; o_x <= mx; o_y <= my;
		end
		if (div == 3'd5) begin
			red   <= dest_v ? pal_dr : 8'd0;
			green <= dest_v ? pal_dg : 8'd0;
			blue  <= dest_v ? pal_db : 8'd0;
			out_x <= o_x; out_y <= o_y; out_valid <= o_vis;
		end else out_valid <= 1'b0;
	end
endmodule
