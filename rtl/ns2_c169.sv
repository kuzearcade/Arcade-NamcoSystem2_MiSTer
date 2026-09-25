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
module ns2_c169 (
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
	// C169 mask ROM: bytes, byte = mask * 32 + row * 2 + (x >> 3), bit 7 leftmost
	output reg        m_req,
	output reg [18:0] m_addr,
	input             m_ack,
	input             m_valid,
	input      [7:0]  m_data,
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
	// burst and mask byte, FIFO B keeps x and the columns until both return
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
	reg [3:0]  bw, br_r, bm;
	reg [4:0]  bcnt;
	reg [63:0] rq [0:15];
	reg [7:0]  mq [0:15];
	reg [3:0]  rwp, mwp;
	reg        t_pend, m_pend;

	wire [13:0] code  = ak_q[ar];
	wire [13:0] tile  = lw ? cb_lw(code) : {1'b0, cb_mh(code)};
	wire        issue = st == S_RUN && acnt + {4'd0, p1_v} + {4'd0, p2_v} < 5'd14;
	wire        pop_a = acnt != 0 && !t_pend && !m_pend && bcnt < 5'd14;
	// both the burst and the mask byte of the oldest pixel are in
	wire        both  = bcnt != 0 && rwp != br_r && mwp != br_r;

	integer k;
	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; r_req <= 1'b0; m_req <= 1'b0; t_pend <= 1'b0; m_pend <= 1'b0;
			p1_v <= 1'b0; p2_v <= 1'b0; aw <= 0; ar <= 0; acnt <= 0; bw <= 0; br_r <= 0; bcnt <= 0; rwp <= 0; mwp <= 0;
		end else begin
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
			// the fetch side: a burst and a mask byte per pixel
			if (pop_a) begin
				r_req <= 1'b1; r_addr <= {tile, apy_q[ar], apx_q[ar][3]};
				m_req <= 1'b1; m_addr <= {code, apy_q[ar], apx_q[ar][3]};
				t_pend <= 1'b1; m_pend <= 1'b1;
				bx_q[bw] <= ax_q[ar]; bpx_q[bw] <= apx_q[ar]; bw <= bw + 1'd1;
				ar <= ar + 1'd1;
			end else begin
				if (r_ack) begin r_req <= 1'b0; t_pend <= 1'b0; end
				if (m_ack) begin m_req <= 1'b0; m_pend <= 1'b0; end
			end
			acnt <= acnt + {4'd0, p2_v} - {4'd0, pop_a};
			// the returns, in order, then the pixel when both are in
			if (r_valid) begin rq[rwp] <= r_data; rwp <= rwp + 1'd1; end
			if (m_valid) begin mq[mwp] <= m_data; mwp <= mwp + 1'd1; end
			if (both) begin
				lb_we <= mq[br_r][3'd7 - bpx_q[br_r][2:0]];
				lb_layer <= w; lb_x <= bx_q[br_r];
				lb_d <= {1'b1, pri, colour, rq[br_r][8 * bpx_q[br_r][2:0] +: 8]};
				br_r <= br_r + 1'd1;
			end
			bcnt <= bcnt + {4'd0, pop_a} - {4'd0, both};
			if (st == S_SETUP) begin rwp <= 0; mwp <= 0; br_r <= 0; bw <= 0; aw <= 0; ar <= 0; end
		end
	end
endmodule
