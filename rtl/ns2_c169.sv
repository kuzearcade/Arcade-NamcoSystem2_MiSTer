// C169 ROZ (namco_c169roz.cpp; tools/ns2_model.py c169_params / c169_rows /
// draw_c169 are the specification): renders one line of both layers, layer 1
// then layer 0, each into its own line buffer with its priority and colour
// per pixel (the per-line mode changes both from line to line).
//
// A layer's parameters are its 8 control words, or for layer 1 when control
// word 0 is 0x8000, 8 words of video RAM at 0x7040 + (y >> 3) * 0x80 +
// (y & 7) * 8 (the per-line mode):
//   [1] bit 15 off, bit 11 no wrap (unused), 9-8 size 512 << n,
//       7-4 priority (0..15), 3-0 colour (x 256)
//   [2..5] incxx, incxy, incyx, incyy: 12 bits and a sign in bit 15;
//       [2], [3] bits 14-12 also give left, top (x 512)
//   [6], [7] startx, starty: start = (s16 << 4) + 36 * incx? + 3 * incy?
// Pixel x of line y reads the 4096 x 4096 map at
//   xpos = (((startx + x*incxx + y*incyx) >> 16) & (size-1)) + left, & 0xfff
// (y likewise): map word ((col & 0x80) << 8) | (row << 7) | (col & 0x7f) of
// 16 x 16 tiles, & 0x3fff, the board's tile callback (Metal Hawk: bitswap13,
// Lucky & Wild: the mangle), then the tile's pixel (gfx_16x16x8_raw) where its
// mask bit is set.
//
// The mask (NS2-21). Zoomed out, each pixel of a line is in a burst of its
// own, and a mask byte fetched per pixel (576 a line) is more random bursts
// than bank 2 serves in a line: Metal Hawk lost every other line in play.
// With MCACHE (Metal Hawk's bitstream; not for Lucky & Wild, `lw`), a tile's
// whole mask (32 bytes, four bursts) is kept in a 512-tile cache by its code.
// The tile is asked for when the pixel's map word arrives (the prefetch), and
// the pixel leaves FIFO A only when its tile is in: it takes its mask bit
// with it, so a later fill of the same entry cannot change it. A fill's
// first burst marks the entry pending and its last marks it filled; reset
// clears the tags. The fills run on through a reset (the memory system does
// not reset with the video, and their bursts still come back).
module ns2_c169 #(parameter MCACHE = 0) (
	input             clk,
	input             reset,
	input             start,
	input      [7:0]  y,
	output reg        busy,
	input             lw,            // Lucky & Wild's tile callback, else Metal Hawk's
	input      [255:0] ctl,          // the 16 control words
	// C169 RAM (32K words), video port: data one clock after the address
	output reg [14:0] vr_addr,
	input      [15:0] vr_data,
	// C169 ROM: 64-bit bursts, burst = tile * 32 + row * 2 + (x >> 3)
	output reg        r_req,
	output reg [20:0] r_addr,
	input             r_ack,
	input             r_valid,
	input      [63:0] r_data,
	// C169 mask ROM: byte = mask * 32 + row * 2 + (x >> 3), bit 7 leftmost; the
	// burst holding the byte comes back (byte n of the burst at [8n +: 8])
	output            m_req,
	output     [18:0] m_addr,
	input             m_ack,
	input             m_valid,
	input      [63:0] m_data,
	// the layers' line buffers: {valid, priority[3:0], colour[11:0]}
	output reg        lb_we,
	output reg        lb_layer,      // 1 or 0
	output reg [8:0]  lb_x,
	output reg [16:0] lb_d
);
	function signed [31:0] s12(input [15:0] t);
		s12 = t[15] ? {{16{1'b1}}, 4'hf, t[11:0]} : {20'd0, t[11:0]};
	endfunction
	function [12:0] cb_mh(input [13:0] c);     // bitswap<13>(c & 0x1fff, 11,10,9,12,8..0)
		cb_mh = {c[11], c[10], c[9], c[12], c[8:0]};
	endfunction
	function [13:0] cb_lw(input [13:0] c);     // bitswap<11>(c & 0x31ff, 13,12,8..0), then by bits 11-9
		reg [13:0] m;
		begin
			m = {3'd0, c[13], c[12], c[8:0]};
			case (c[11:9])
				3'd0: cb_lw = m + 14'h1c00;
				3'd1: cb_lw = m | 14'h0800;
				default: cb_lw = m;
			endcase
		end
	endfunction

	localparam S_IDLE = 0, S_LAYER = 1, S_PRM = 2, S_SETUP = 3, S_RUN = 4, S_DRAIN = 5;
	reg [2:0]  st;
	reg        w;                 // the layer
	reg [7:0]  yl;
	reg [15:0] src [0:7];
	reg [3:0]  pn;                // per-line parameter reads
	reg [31:0] ax, ay, dxx, dxy;
	reg [11:0] size_m;
	reg [11:0] left, top;
	reg [3:0]  pri;
	reg [3:0]  colour;
	reg [8:0]  x;

	wire [15:0] c0 = ctl[0 +: 16];
	wire        per_line = w && c0 == 16'h8000;

	// the parameters, unpacked
	wire signed [31:0] incxx = s12(src[2]), incxy = s12(src[3]), incyx = s12(src[4]), incyy = s12(src[5]);
	wire signed [31:0] startx = ($signed({{16{src[6][15]}}, src[6]}) <<< 4) + 36 * incxx + 3 * incyx;
	wire signed [31:0] starty = ($signed({{16{src[7][15]}}, src[7]}) <<< 4) + 36 * incxy + 3 * incyy;

	wire [11:0] xpos = ((ax[27:16] & size_m) + left) & 12'hfff;
	wire [11:0] ypos = ((ay[27:16] & size_m) + top) & 12'hfff;
	wire [7:0]  mcol = xpos[11:4], mrow = ypos[11:4];

	// the pipeline (as ns2_roz): p1 issues the map read, p2 waits, FIFO A
	// holds the pixel with its map word, the fetch side issues the pixel's
	// burst (and, without the mask cache, its mask byte), FIFO B keeps x and
	// the columns until they return
	wire       mc = MCACHE != 0 && !lw;     // the mask cache is in use
	reg        p1_v, p2_v;
	reg [8:0]  p1_x, p2_x;
	reg [3:0]  p1_px, p2_px, p1_py, p2_py;
	reg [8:0]  ax_q [0:15];
	reg [3:0]  apx_q [0:15], apy_q [0:15];
	reg [13:0] ak_q [0:15];
	reg [3:0]  aw, ar;
	reg [4:0]  acnt;
	reg [8:0]  bx_q [0:15];
	reg [3:0]  bpx_q [0:15];
	reg        bm_q [0:15];                 // with the cache: the pixel's mask bit
	reg [3:0]  bw, br_r;
	reg [4:0]  bcnt;
	reg [63:0] rq [0:15];
	reg [7:0]  mq [0:15];
	reg [2:0]  mo_q [0:15];                 // without the cache: each mask request's byte in its burst
	reg [4:0]  rwp, mwp;                // bursts / mask bytes back (mod 32)
	reg        t_pend, m_pend;
	reg        o_req;                   // without the cache: the mask request
	reg [18:0] o_addr;
	// A pixel in the same tile row half as the last request takes that
	// request's burst (and mask byte): each pending pixel keeps the number of
	// its request. At most 14 pixels wait, so a request's slot in rq / mq
	// lives until its last pixel is drawn.
	reg [4:0]  ic;                      // requests issued (mod 32)
	reg [4:0]  bb_q [0:15];             // a pending pixel's request number
	reg [18:0] last_key;
	reg        last_v;
	wire [4:0]  bb = bb_q[br_r];
	wire [4:0]  r_got = rwp - bb, m_got = mwp - bb;

	wire [13:0] code  = ak_q[ar];
	wire [13:0] tile  = lw ? cb_lw(code) : {1'b0, cb_mh(code)};
	wire [18:0] key = {code, apy_q[ar], apx_q[ar][3]};
	wire        reuse = last_v && key == last_key;
	wire        issue = st == S_RUN && acnt + {4'd0, p1_v} + {4'd0, p2_v} < 5'd14;

	// ------------------------------------------------------------ the mask cache
	// 512 tiles by the code's low 9 bits; a tag is {filled, pending, code}.
	localparam CE = MCACHE != 0 ? 511 : 0;
	reg [63:0] md [0:CE * 4 + 3];           // entry * 4 + burst: rows 4q .. 4q + 3
	reg [15:0] tg_a [0:CE], tg_b [0:CE];    // the same tags: the prefetch's copy, the head's
	reg        tg_we, md_we;
	reg [8:0]  tg_wa;
	reg [15:0] tg_wd;
	reg [10:0] md_wa;
	reg [9:0]  clr;                          // reset: the tags cleared, entry by entry
	// the prefetch: the map word a stage after p2, its tag a stage later
	reg        p3_v, p4_v;
	reg [13:0] p3_code, p4_code, last_alloc;
	reg [15:0] pf_tag;
	// the head of FIFO A: its tag and its burst of mask, read a clock ago
	reg [15:0] hd_tag;
	reg [63:0] hd_md;
	reg [3:0]  hd_ar;
	reg        hd_ok, hd_w;
	// the fills: codes to fetch, and tiles in flight (four bursts each, in order)
	reg [13:0] ff_q [0:7];
	reg [3:0]  ff_w = 0, ff_r = 0;
	reg [13:0] if_q [0:3];
	reg [2:0]  if_w = 0, if_r = 0;
	reg [1:0]  fq = 0, mret = 0;             // a fill's burst out, and back
	reg        f_req = 1'b0;
	reg [13:0] f_code = 14'd0;               // the tile being asked for
	reg [18:0] f_addr = 19'd0;
	assign m_req  = mc ? f_req : o_req;
	assign m_addr = mc ? f_addr : o_addr;
	wire [8:0]  hd_idx = code[8:0];
	wire        hd_cur = mc && clr[9] && hd_ok && hd_ar == ar && acnt != 0 && !hd_w;
	wire        head_hit = hd_cur && hd_tag[15] && hd_tag[13:0] == code;
	wire        head_miss = hd_cur && !(hd_tag[13:0] == code && (hd_tag[15] || hd_tag[14]));
	wire        pf_miss = mc && p4_v && !(pf_tag[13:0] == p4_code && (pf_tag[15] || pf_tag[14])) && p4_code != last_alloc;
	wire [7:0]  hd_byte = hd_md[8 * {apy_q[ar][1:0], apx_q[ar][3]} +: 8];
	wire        hd_bit = hd_byte[3'd7 - apx_q[ar][2:0]];
	wire [13:0] ret_code = if_q[if_r[1:0]];
	// the tag port: a fill's first and last burst, else one allocation
	wire        fill_tag = m_valid && mc && (mret == 2'd0 || mret == 2'd3);
	wire        ff_room = (ff_w - ff_r) < 4'd8;
	wire        alloc = (head_miss || pf_miss) && ff_room && !fill_tag && clr[9];
	wire [13:0] alloc_code = head_miss ? code : p4_code;
	always @(*) begin
		tg_we = 1'b0; tg_wa = 9'd0; tg_wd = 16'd0;
		if (!clr[9]) begin tg_we = 1'b1; tg_wa = clr[8:0]; end
		else if (fill_tag) begin tg_we = 1'b1; tg_wa = ret_code[8:0]; tg_wd = {mret == 2'd3, mret != 2'd3, ret_code}; end
		else if (alloc) begin tg_we = 1'b1; tg_wa = alloc_code[8:0]; tg_wd = {2'b01, alloc_code}; end
		md_we = m_valid && mc;
		md_wa = {ret_code[8:0], mret};
	end
	always @(posedge clk) begin
		if (tg_we) begin tg_a[tg_wa] <= tg_wd; tg_b[tg_wa] <= tg_wd; end
		pf_tag <= tg_a[p3_code[8:0]];
		hd_tag <= tg_b[hd_idx];
	end
	always @(posedge clk) begin
		if (md_we) md[md_wa] <= m_data;
		hd_md <= md[{hd_idx, apy_q[ar][3:2]}];
	end

	wire        pop_a = acnt != 0 && !t_pend && (mc ? head_hit : !m_pend) && bcnt < 5'd14;
	// the oldest pixel's burst is in (and without the cache, its mask byte)
	wire        both  = bcnt != 0 && r_got != 5'd0 && r_got <= 5'd16 && (mc || (m_got != 5'd0 && m_got <= 5'd16));

	// the fills: four bursts a tile, at most four tiles in flight; not reset
	// (ff_q takes an allocation, in the block below)
	always @(posedge clk) begin
		if (alloc) begin ff_q[ff_w[2:0]] <= alloc_code; ff_w <= ff_w + 1'd1; end
		if (mc) begin
			// a tile goes into the in-flight ring as its first burst is asked
			// for: its bursts can come back before its last is acknowledged
			if (f_req && m_ack) begin
				fq <= fq + 1'd1;
				if (fq == 2'd3) f_req <= 1'b0;
				else f_addr <= {f_code, fq + 2'd1, 3'd0};
			end else if (!f_req && ff_w != ff_r && (if_w - if_r) < 3'd4) begin
				f_code <= ff_q[ff_r[2:0]]; ff_r <= ff_r + 1'd1;
				if_q[if_w[1:0]] <= ff_q[ff_r[2:0]]; if_w <= if_w + 1'd1;
				f_req <= 1'b1; f_addr <= {ff_q[ff_r[2:0]], 2'd0, 3'd0};
			end
			if (m_valid) begin
				mret <= mret + 1'd1;
				if (mret == 2'd3) if_r <= if_r + 1'd1;
			end
		end
	end

	integer k;
	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; r_req <= 1'b0; o_req <= 1'b0; t_pend <= 1'b0; m_pend <= 1'b0;
			p1_v <= 1'b0; p2_v <= 1'b0; aw <= 0; ar <= 0; acnt <= 0; bw <= 0; br_r <= 0; bcnt <= 0; rwp <= 0; mwp <= 0;
			ic <= 0; last_v <= 1'b0;
			clr <= 0; p3_v <= 1'b0; p4_v <= 1'b0; hd_ok <= 1'b0; last_alloc <= 14'h3fff;
		end else begin
			if (!clr[9]) clr <= clr + 1'd1;
			case (st)
				S_IDLE: if (start) begin yl <= y; w <= 1'b1; busy <= 1'b1; st <= S_LAYER; end
				S_LAYER: begin
					if (per_line) begin
						// 8 words of video RAM, back to back
						pn <= 0; st <= S_PRM;
					end else begin
						for (k = 0; k < 8; k = k + 1) src[k] <= ctl[16 * (w * 8 + k) +: 16];
						st <= S_SETUP;
					end
				end
				S_PRM: begin
					if (pn < 4'd8) vr_addr <= 15'h7040 + {yl[7:3], 7'd0} + {yl[2:0], 3'd0} + pn;
					if (pn >= 4'd2) src[pn - 4'd2] <= vr_data;
					if (pn == 4'd9) st <= S_SETUP;
					pn <= pn + 1'd1;
				end
				S_SETUP: begin
					if (src[1][15]) begin
						// the layer is off
						if (w) begin w <= 1'b0; st <= S_LAYER; end
						else begin busy <= 1'b0; st <= S_IDLE; end
					end else begin
						ax <= startx * 256 + $signed({1'b0, yl}) * (incyx * 256);
						ay <= starty * 256 + $signed({1'b0, yl}) * (incyy * 256);
						dxx <= incxx * 256; dxy <= incxy * 256;
						size_m <= (12'd512 << src[1][9:8]) - 1'd1;
						left <= {src[2][14:12], 9'd0}; top <= {src[3][14:12], 9'd0};
						pri <= src[1][7:4]; colour <= src[1][3:0];
						x <= 0;
						st <= S_RUN;
					end
				end
				S_RUN: if (issue && x == 9'd287) st <= S_DRAIN;
				S_DRAIN: if (!p1_v && !p2_v && acnt == 0 && !t_pend && !m_pend && bcnt == 0) begin
					if (w) begin w <= 1'b0; st <= S_LAYER; end
					else begin busy <= 1'b0; st <= S_IDLE; end
				end
				default: st <= S_IDLE;
			endcase
			// p1: the map read
			p1_v <= issue;
			if (issue) begin
				p1_x <= x; p1_px <= xpos[3:0]; p1_py <= ypos[3:0];
				vr_addr <= {mrow, mcol[6:0]};        // ((col & 0x80) << 8) | (row << 7) | (col & 0x7f), & 0x7fff
				ax <= ax + dxx; ay <= ay + dxy;
				x <= x + 1'd1;
			end
			p2_v <= p1_v; p2_x <= p1_x; p2_px <= p1_px; p2_py <= p1_py;
			if (p2_v) begin
				ax_q[aw] <= p2_x; apx_q[aw] <= p2_px; apy_q[aw] <= p2_py; ak_q[aw] <= vr_data[13:0];
				aw <= aw + 1'd1;
			end
			// the cache's prefetch and its view of the head
			p3_v <= mc && p2_v; p3_code <= vr_data[13:0];
			p4_v <= p3_v; p4_code <= p3_code;
			hd_ok <= acnt != 0 && st != S_SETUP;
			hd_ar <= ar;
			hd_w <= md_we && md_wa[10:2] == hd_idx;
			if (alloc) last_alloc <= alloc_code;
			// the fetch side: a burst per pixel (a mask byte too, without the cache)
			if (pop_a) begin
				if (reuse) bb_q[bw] <= ic - 1'd1;
				else begin
					r_req <= 1'b1; r_addr <= {tile, apy_q[ar], apx_q[ar][3]};
					t_pend <= 1'b1;
					if (!mc) begin
						o_req <= 1'b1; o_addr <= {code, apy_q[ar], apx_q[ar][3]}; m_pend <= 1'b1;
						mo_q[ic[3:0]] <= {apy_q[ar][1:0], apx_q[ar][3]};
					end
					bb_q[bw] <= ic; ic <= ic + 1'd1;
					last_key <= key; last_v <= 1'b1;
				end
				bx_q[bw] <= ax_q[ar]; bpx_q[bw] <= apx_q[ar]; bm_q[bw] <= hd_bit; bw <= bw + 1'd1;
				ar <= ar + 1'd1;
			end else begin
				if (r_ack) begin r_req <= 1'b0; t_pend <= 1'b0; end
				if (m_ack && !mc) begin o_req <= 1'b0; m_pend <= 1'b0; end
			end
			acnt <= acnt + {4'd0, p2_v} - {4'd0, pop_a};
			// the returns, in order, then the pixel when it has what it needs
			if (r_valid) begin rq[rwp[3:0]] <= r_data; rwp <= rwp + 1'd1; end
			if (m_valid && !mc) begin mq[mwp[3:0]] <= m_data[8 * mo_q[mwp[3:0]] +: 8]; mwp <= mwp + 1'd1; end
			if (both) begin
				lb_we <= mc ? bm_q[br_r] : mq[bb[3:0]][3'd7 - bpx_q[br_r][2:0]];
				lb_layer <= w; lb_x <= bx_q[br_r];
				lb_d <= {1'b1, pri, colour, rq[bb[3:0]][8 * bpx_q[br_r][2:0] +: 8]};
				br_r <= br_r + 1'd1;
			end
			bcnt <= bcnt + {4'd0, pop_a} - {4'd0, both};
			if (st == S_SETUP) begin rwp <= 0; mwp <= 0; br_r <= 0; bw <= 0; aw <= 0; ar <= 0; ic <= 0; last_v <= 1'b0; end
		end
	end
endmodule
