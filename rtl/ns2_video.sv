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
module ns2_video (
	input             clk,
	input             reset,
	// the board: 0 standard (ROZ A, sprites A), 1 Final Lap (C45 road,
	// sprites A with 4-bit priority, priorities 0..15)
	input      [2:0]  board,
	input             tile_fl2,     // finalap2 / finalap3 tile callback
	input             spr_fl,       // finallap: namcos2_sprite_finallap_device
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
	output            posirq_line,  // the C116 raster line (reg 5) is here
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
	output            spr_req,
	output     [18:0] spr_addr,
	input             spr_ack,
	input             spr_valid,
	input      [63:0] spr_data,
	// a line was not rendered in time (the testbenches fail on it)
	output reg        overrun
);
	// ------------------------------------------------------------ raster
	reg [2:0] div;
	assign ce_pix = div == 3'd7;
	always @(posedge clk) begin
		if (reset) begin div <= 0; hcnt <= 0; vcnt <= 0; end
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
	endgenerate
	assign posirq_line = vcnt[7:0] == c116[5][7:0];

	// ------------------------------------------------------------ RAMs
	// two ports each: the CPU's and the video's (Intel's true dual port
	// template in 8-bit lanes, docs/PLAN.md Appendix F)
	reg [7:0]  tmap_h [0:32767] /*verilator public_flat_rw*/, tmap_l [0:32767] /*verilator public_flat_rw*/;
	reg [7:0]  spr_h  [0:8191]  /*verilator public_flat_rw*/, spr_l  [0:8191]  /*verilator public_flat_rw*/;
	reg [7:0]  roz_h  [0:65535] /*verilator public_flat_rw*/, roz_l  [0:65535] /*verilator public_flat_rw*/;
	reg [7:0]  clut   [0:255]   /*verilator public_flat_rw*/;   // C45 road CLUT (ROM)
	reg [7:0]  pal_r  [0:8191]  /*verilator public_flat_rw*/, pal_g  [0:8191]  /*verilator public_flat_rw*/,
	           pal_b  [0:8191]  /*verilator public_flat_rw*/;

	wire cw = !cpu_rnw;
	reg [15:0] tmap_q, spr_q, roz_q;
	reg [7:0]  pal_q;
	reg [2:0]  rsel;
	// the C116's space: word o, plane (o >> 11) & 3 (R, G, B, registers),
	// colour ((o & 0x6000) >> 2) | (o & 0x7ff); the low byte is the data
	wire [14:0] po     = cpu_addr[15:1];
	wire [1:0]  pplane = po[12:11];
	wire [12:0] pcol   = {po[14:13], po[10:0]};
	always @(posedge clk) begin
		if (cs_tmap) begin
			if (cw && cpu_uds) tmap_h[cpu_addr[15:1]] <= cpu_dout[15:8];
			if (cw && cpu_lds) tmap_l[cpu_addr[15:1]] <= cpu_dout[7:0];
			tmap_q <= {tmap_h[cpu_addr[15:1]], tmap_l[cpu_addr[15:1]]};
		end
		if (cs_spr) begin
			if (cw && cpu_uds) spr_h[cpu_addr[13:1]] <= cpu_dout[15:8];
			if (cw && cpu_lds) spr_l[cpu_addr[13:1]] <= cpu_dout[7:0];
			spr_q <= {spr_h[cpu_addr[13:1]], spr_l[cpu_addr[13:1]]};
		end
		if (cs_roz) begin
			if (cw && cpu_uds) roz_h[cpu_addr[16:1]] <= cpu_dout[15:8];
			if (cw && cpu_lds) roz_l[cpu_addr[16:1]] <= cpu_dout[7:0];
			roz_q <= {roz_h[cpu_addr[16:1]], roz_l[cpu_addr[16:1]]};
		end
		if (cs_pal) begin
			if (cw && cpu_lds && pplane == 2'd0) pal_r[pcol] <= cpu_dout[7:0];
			if (cw && cpu_lds && pplane == 2'd1) pal_g[pcol] <= cpu_dout[7:0];
			if (cw && cpu_lds && pplane == 2'd2) pal_b[pcol] <= cpu_dout[7:0];
			if (cw && cpu_lds && pplane == 2'd3) begin
				if (po[0]) c116[po[3:1]][7:0] <= cpu_dout[7:0];
				else       c116[po[3:1]][15:8] <= cpu_dout[7:0];
			end
			pal_q <= pplane == 2'd0 ? pal_r[pcol] : pplane == 2'd1 ? pal_g[pcol] :
			         pplane == 2'd2 ? pal_b[pcol] : (po[0] ? c116[po[3:1]][7:0] : c116[po[3:1]][15:8]);
		end
		if (cs_tctl && cw) begin
			if (cpu_uds) tctl[cpu_addr[5:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) tctl[cpu_addr[5:1]][7:0]  <= cpu_dout[7:0];
		end
		if (cs_gfx && cw) begin
			if (cpu_uds) gfx_ctrl[15:8] <= cpu_dout[15:8];
			if (cpu_lds) gfx_ctrl[7:0]  <= cpu_dout[7:0];
		end
		if (cs_rozctl && cw) begin
			if (cpu_uds) rozctl[cpu_addr[3:1]][15:8] <= cpu_dout[15:8];
			if (cpu_lds) rozctl[cpu_addr[3:1]][7:0]  <= cpu_dout[7:0];
		end
		rsel <= cs_tmap ? 3'd0 : cs_spr ? 3'd1 : cs_roz ? 3'd2 : cs_pal ? 3'd3 :
		        cs_tctl ? 3'd4 : cs_gfx ? 3'd5 : 3'd6;
	end
	reg [15:0] reg_q;
	always @(posedge clk) reg_q <= cs_tctl ? tctl[cpu_addr[5:1]] : cs_gfx ? gfx_ctrl : rozctl[cpu_addr[3:1]];
	always @(*) case (rsel)
		3'd0: cpu_din = tmap_q;
		3'd1: cpu_din = spr_q;
		3'd2: cpu_din = roz_q;
		3'd3: cpu_din = {8'hff, pal_q};
		default: cpu_din = reg_q;
	endcase

	// video ports (the ROZ RAM is the road RAM on Final Lap)
	wire        fl = board == 3'd1;
	wire [14:0] vt_addr;
	wire [12:0] vs_addr;
	wire [15:0] vr_addr_roz, vr_addr_road;
	wire [15:0] vr_addr = fl ? vr_addr_road : vr_addr_roz;
	wire [7:0]  clut_addr;
	reg  [15:0] vt_q, vs_q, vr_q;
	reg  [7:0]  clut_q;
	always @(posedge clk) begin
		vt_q <= {tmap_h[vt_addr], tmap_l[vt_addr]};
		vs_q <= {spr_h[vs_addr], spr_l[vs_addr]};
		vr_q <= {roz_h[vr_addr], roz_l[vr_addr]};
		clut_q <= clut[clut_addr];
	end

	// ------------------------------------------------------------ line sequencing
	// at the start of display line v, render line v + 1 (line 0 during 263)
	wire [8:0] vnext = vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
	reg        go;
	reg  [7:0] ry;
	wire       c123_busy, roz_busy, road_busy, spr_busy;
	always @(posedge clk) begin
		go <= 1'b0;
		overrun <= 1'b0;
		if (!reset && ce_pix && hcnt == 9'd0 && vnext < 9'd224) begin
			if (c123_busy || roz_busy || road_busy || spr_busy) overrun <= 1'b1;
			go <= 1'b1; ry <= vnext[7:0];
		end
	end

	wire        c_we, r_we_roz, r_we_road, s_we;
	wire [8:0]  c_x, r_x_roz, r_x_road, s_x;
	wire [16:0] c_d;
	wire [8:0]  r_d_roz, r_d_road;
	wire [16:0] s_d;
	wire        r_we = fl ? r_we_road : r_we_roz;
	wire [8:0]  r_x  = fl ? r_x_road  : r_x_roz;
	wire [8:0]  r_d  = fl ? r_d_road  : r_d_roz;
	wire        road_attr_we;
	wire [3:0]  road_pri;

	ns2_c123 u_c123 (
		.clk(clk), .reset(reset), .start(go), .y(ry), .busy(c123_busy), .ctl(tctl_flat), .tile_fl2(tile_fl2),
		.vr_addr(vt_addr), .vr_data(vt_q),
		.t_req(tile_req), .t_addr(tile_addr), .t_ack(tile_ack), .t_valid(tile_valid), .t_data(tile_data),
		.m_req(tmask_req), .m_addr(tmask_addr), .m_ack(tmask_ack), .m_valid(tmask_valid), .m_data(tmask_data),
		.lb_we(c_we), .lb_x(c_x), .lb_d(c_d));

	ns2_roz u_roz (
		.clk(clk), .reset(reset), .start(go && !fl), .y(ry), .busy(roz_busy), .ctl(rozctl_flat),
		.rr_addr(vr_addr_roz), .rr_data(vr_q),
		.r_req(roz_req), .r_addr(roz_addr), .r_ack(roz_ack), .r_valid(roz_valid), .r_data(roz_data),
		.lb_we(r_we_roz), .lb_x(r_x_roz), .lb_d(r_d_roz));

	ns2_c45 u_road (
		.clk(clk), .reset(reset), .start(go && fl), .y(ry), .busy(road_busy),
		.rd_addr(vr_addr_road), .rd_data(vr_q), .clut_addr(clut_addr), .clut_data(clut_q),
		.attr_we(road_attr_we), .attr_pri(road_pri),
		.lb_we(r_we_road), .lb_x(r_x_road), .lb_d(r_d_road));

	ns2_sprite_a u_spr (
		.clk(clk), .reset(reset), .start(go), .y(ry), .busy(spr_busy), .gfx_ctrl(gfx_ctrl), .pri4(fl), .spr_fl(spr_fl),
		.sr_addr(vs_addr), .sr_data(vs_q),
		.s_req(spr_req), .s_addr(spr_addr), .s_ack(spr_ack), .s_valid(spr_valid), .s_data(spr_data),
		.lb_we(s_we), .lb_x(s_x), .lb_d(s_d));

	// the ROZ plane's (or the road line's) attributes, with its buffer:
	// {priority 0..15, colour bank}
	reg [7:0] roz_attr [0:1];
	always @(posedge clk) begin
		if (go && !fl) roz_attr[ry[0]] <= {1'b0, gfx_ctrl[14:12], gfx_ctrl[11:8]};
		if (road_attr_we) roz_attr[ry[0]] <= {road_pri, 4'hf};
	end

	// ------------------------------------------------------------ line buffers
	// {buffer = line & 1, x}; the renderers write the next line's, the display
	// reads the current line's and clears each pixel after reading it
	reg [16:0] lb_c [0:1023];
	reg [8:0]  lb_r [0:1023];
	reg [16:0] lb_s [0:1023];
	reg [16:0] qc;
	reg [8:0]  qr;
	reg [16:0] qs;
	wire       wb = ry[0];
	wire [9:0] da = {vcnt[0], hcnt};
	wire       dvis = vcnt < 9'd224 && hcnt < 9'd288;
	always @(posedge clk) begin
		if (c_we) lb_c[{wb, c_x}] <= c_d;
		if (r_we) lb_r[{wb, r_x}] <= r_d;
		if (s_we) lb_s[{wb, s_x}] <= s_d;
	end
	always @(posedge clk) begin
		if (div == 3'd1 && dvis) begin lb_c[da] <= 17'd0; lb_r[da] <= 9'd0; lb_s[da] <= 17'd0; end
		qc <= lb_c[da]; qr <= lb_r[da]; qs <= lb_s[da];
	end

	// ------------------------------------------------------------ mix
	// div 0: address set (hcnt is this pixel); div 1: buffers read; div 2: mix;
	// div 3: palette read; div 4: out
	wire signed [10:0] x0 = $signed({2'b0, c116[0][8:0]}) - 11'sd74;
	wire signed [10:0] x1 = $signed({2'b0, c116[1][8:0]}) - 11'sd75;
	wire signed [10:0] y0 = $signed({2'b0, c116[2][8:0]}) - 11'sd33;
	wire signed [10:0] y1 = $signed({2'b0, c116[3][8:0]}) - 11'sd34;
	reg  [8:0]  mx;
	reg  [7:0]  my;
	reg         mvis, dest_v;
	reg  [12:0] dest;
	reg         o_v, o_vis;
	reg  [8:0]  o_x;
	reg  [7:0]  o_y;
	wire        inclip = $signed({2'b0, mx}) >= x0 && $signed({2'b0, mx}) <= x1 &&
	                     $signed({3'b0, my}) >= y0 && $signed({3'b0, my}) <= y1;
	wire [7:0]  rattr  = roz_attr[my[0]];
	// priorities on the board's scale: standard 0..7 (ROZ after the planes
	// of its priority); Final Lap 0..15 with plane p at 2p (road after them)
	wire [3:0]  c_pv   = fl ? {qc[15:13], 1'b0} : {1'b0, qc[15:13]};
	wire [3:0]  r_pv   = rattr[7:4];
	wire        r_win  = qr[8] && (!qc[16] || c_pv <= r_pv);
	wire        b_v    = inclip && (r_win || qc[16]);
	wire [12:0] b_col  = r_win ? {1'b0, rattr[3:0], qr[7:0]} : qc[12:0];
	wire [3:0]  b_pri  = !b_v ? 4'd0 : r_win ? r_pv : c_pv;
	// sprites
	wire        s_on   = qs[16] && inclip && b_pri <= qs[15:12];
	wire        shadow = qs[11:0] == 12'hffe;
	always @(posedge clk) begin
		if (div == 3'd1) begin mx <= hcnt; my <= vcnt[7:0]; mvis <= dvis; end
		if (div == 3'd2) begin
			if (s_on && !shadow)            begin dest_v <= 1'b1; dest <= {1'b0, qs[11:0]}; end
			else if (s_on && shadow)        begin dest_v <= b_v && b_col[12]; dest <= b_col | 13'h0800; end
			else                            begin dest_v <= b_v; dest <= b_col; end
			o_vis <= mvis; o_x <= mx; o_y <= my;
		end
		if (div == 3'd4) begin
			red   <= dest_v ? pal_r[dest] : 8'd0;
			green <= dest_v ? pal_g[dest] : 8'd0;
			blue  <= dest_v ? pal_b[dest] : 8'd0;
			out_x <= o_x; out_y <= o_y; out_valid <= o_vis;
		end else out_valid <= 1'b0;
	end
endmodule
