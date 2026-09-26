// Sprites (A) (namcos2_sprite.cpp draw_sprites; tools/ns2_model.py
// sprites_a is the specification): renders one line of the 128 sprites of
// the bank gfx_ctrl & 0xf into the sprite line buffer, in list order, a
// later sprite overwriting an earlier one.
//
// A sprite is 32x32 (w0 bit 9) or a 16x16 quarter of one (w1 bits 0, 1),
// 8 bpp, pen 0xff transparent. MAME's zoom reduces to a screen size of
// sizex x sizey (sizex halved for 16x16), the source stepping by
// (gw << 16) / size per screen pixel, from the far edge when flipped:
//   row = ((flipy ? sh - 1 - i : i) * dy) >> 16, col likewise.
//   ypos = (0x1ff - (w0 & 0x1ff)) - 0x50 + 2, xpos = (w2 & 0x7ff) - 0x50 + 7
// The sprite ROM row is 32 bytes (obj_layout: four bytes carry four pixels,
// bit planes interleaved), fetched as four 64-bit bursts.
// Clipping is left to the mixer, which masks the whole picture with the
// C116 window: drawing outside it changes nothing that is shown.
module ns2_sprite_a (
	input             clk,
	input             reset,
	input             start,
	input      [7:0]  y,
	output reg        busy,
	input      [15:0] gfx_ctrl,
	input             pri4,          // the priority callback: 4 bits (finallap), else & 7
	input             spr_fl,        // Final Lap's older board: sprite w1[12:2], 32 wide = w1[13]
	input             mh,            // Metal Hawk: 8 words a sprite, raw 8 bpp rows, rot90
	// sprite RAM, video port: data one clock after the address
	output reg [12:0] sr_addr,
	input      [15:0] sr_data,
	// sprite ROM: 64-bit bursts, burst = sprite * 128 + row * 4 + group pair;
	// bit 19: Metal Hawk's xy-swapped decode (a transposed copy of the ROM)
	output reg        s_req,
	output reg [19:0] s_addr,
	input             s_ack,
	input             s_valid,
	input      [63:0] s_data,
	// sprite line buffer: {valid, pri[3:0], colour[11:0]}
	output reg        lb_we,
	output reg [8:0]  lb_x,
	output reg [16:0] lb_d
);
	// (gw << 16) / n for n = 1..64, gw = 16 or 32: MAME's zoom step, from a
	// table of (32 << 16) / n (a divider does not fit a clock); for gw 16 it
	// is halved, floor(floor(x / n) / 2) being floor(x / 2n)
	reg [21:0] ztab [0:127];
	integer zi;
	initial for (zi = 0; zi < 128; zi = zi + 1) ztab[zi] = zi == 0 ? 22'd0 : 22'd2097152 / zi;
	function [21:0] zstep(input g32, input [6:0] n);
		zstep = g32 ? ztab[n] : {1'b0, ztab[n][21:1]};
	endfunction

	// the four pixels of a 4-byte group (obj_layout): pixel k's planes
	// 0..7 (MSB first) are bits 7-k and 3-k of bytes 0..3
	function [7:0] opix(input [31:0] g, input [1:0] k);
		opix = {g[7 - k], g[3 - k], g[15 - k], g[11 - k], g[23 - k], g[19 - k], g[31 - k], g[27 - k]};
	endfunction

	localparam S_IDLE = 0, S_W0 = 1, S_W0D = 2, S_W0C = 3, S_W1 = 4, S_W2 = 5, S_W3 = 6, S_W3D = 7,
	           S_CHK = 8, S_ROW = 9, S_FETCH = 10, S_WAIT = 11, S_DRAW = 12, S_NEXT = 13, S_W4 = 14, S_W4D = 15;
	reg [3:0]  st;
	reg [7:0]  yl;
	reg [6:0]  n;              // sprite index
	reg [12:0] base;
	reg [15:0] w0, w1, w2, w3, w6;     // Metal Hawk: w2 = word 3, w3 = word 7, w6 = word 6
	reg [1:0]  wsel;
	reg [7:0]  row_pix [0:31];
	reg [2:0]  nreq, nrx;
	reg [6:0]  j;
	reg [21:0] dxs, dys;
	reg [27:0] acc;

	wire        is32  = mh ? w6[3] : spr_fl ? w1[13] : w0[9];
	wire [6:0]  sizey = {1'b0, w0[15:10]} + 7'd1;
	wire [5:0]  sx0   = mh ? w2[15:10] : w3[15:10];
	// the screen width: MAME's (scalex * gw + 0x8000) >> 16; Metal Hawk's
	// scalex always divides by 0x20, so a 16-wide sprite is (sizex + 1) / 2
	wire [6:0]  sw    = mh ? (is32 ? {1'b0, sx0} : ({1'b0, sx0} + 7'd1) >> 1)
	                       : (is32 ? {1'b0, sx0} : {2'b0, sx0[5:1]});
	wire [6:0]  sh    = sizey;
	// Metal Hawk moves a smaller 32 x 32 sprite: x - (32 - w) / 8, y + (32 - h) / 12
	wire [5:0]  gx    = 6'd32 - sx0[5:0];
	wire [5:0]  gy    = 6'd32 - sizey[5:0];
	wire [2:0]  adjx  = (mh && is32 && sx0 < 6'd32) ? gx[5:3] : 3'd0;
	wire [1:0]  adjy  = (mh && is32 && sizey < 7'd32) ? (gy >= 6'd24 ? 2'd2 : gy >= 6'd12 ? 2'd1 : 2'd0) : 2'd0;
	wire signed [10:0] ypos = 11'sd433 - $signed({2'b0, w0[8:0]}) + $signed({9'd0, adjy});   // (0x1ff - y) - 0x50 + 2
	wire signed [12:0] xpos = (mh ? $signed({3'b0, w2[9:0]}) : $signed({2'b0, w2[10:0]})) - 13'sd73 - $signed({10'd0, adjx});
	wire signed [11:0] yrel = $signed({4'b0, yl}) - ypos;
	wire        gw32  = is32;
	wire [4:0]  qy    = (!is32 && w1[1]) ? 5'd16 : 5'd0;
	wire [4:0]  qx    = (!is32 && w1[0]) ? 5'd16 : 5'd0;
	wire        flipx = mh ? w6[1] : w1[14], flipy = mh ? w6[2] : w1[15];
	wire [11:0] sprn  = spr_fl ? {1'b0, w1[12:2]} : w1[13:2];
	wire [3:0]  spri  = mh ? w3[3:0] : {pri4 && w3[3], w3[2:0]};
	wire [3:0]  scol  = w3[7:4];

	// the row this line shows, and the drawn pixel's source column
	wire [6:0]  ii    = flipy ? sh - 7'd1 - yrel[6:0] : yrel[6:0];
	wire [28:0] rowp  = ii * dys;
	wire [4:0]  row   = rowp[20:16] + qy;
	wire [6:0]  jj    = flipx ? sw - 7'd1 - j : j;
	wire [28:0] colp  = jj * dxs;
	wire [4:0]  col   = colp[20:16];
	wire signed [13:0] xs = xpos + $signed({7'd0, j});
	wire [7:0]  pen   = row_pix[col];

	integer b;
	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; s_req <= 1'b0;
		end else case (st)
			S_IDLE: if (start) begin
				yl <= y; n <= 0; base <= {gfx_ctrl[3:0], 9'd0}; busy <= 1'b1; st <= S_W0;
			end
			// w0 first: most sprites are not on this line
			S_W0:  begin sr_addr <= mh ? {n, 3'd0} : base + {4'd0, n, 2'd0}; st <= S_W0D; end
			S_W0D: st <= S_W0C;
			S_W0C: begin
				w0 <= sr_data;
				sr_addr <= mh ? {n, 3'd1} : base + {4'd0, n, 2'd1}; st <= S_W1;
			end
			S_W1: begin
				// w0 is in: the line test (sh >= 2 is MAME's sizey - 1 != 0);
				// Metal Hawk's position also depends on word 6, so it tests later
				if (!mh && ($signed({4'b0, yl}) < ypos || $signed({4'b0, yl}) >= ypos + $signed({4'b0, sh}) || sh < 7'd2))
					st <= S_NEXT;
				else begin sr_addr <= mh ? {n, 3'd3} : base + {4'd0, n, 2'd2}; st <= S_W2; end
			end
			S_W2: begin w1 <= sr_data; sr_addr <= mh ? {n, 3'd6} : base + {4'd0, n, 2'd3}; st <= S_W3; end
			S_W3: begin w2 <= sr_data; if (mh) sr_addr <= {n, 3'd7}; st <= S_W3D; end
			S_W3D: begin
				if (mh) begin w6 <= sr_data; st <= S_W4; end
				else begin w3 <= sr_data; st <= S_CHK; end
			end
			S_W4: begin w3 <= sr_data; st <= S_W4D; end
			S_W4D: begin
				if ($signed({4'b0, yl}) < ypos || $signed({4'b0, yl}) >= ypos + $signed({4'b0, sh}) || sh < 7'd2) st <= S_NEXT;
				else st <= S_CHK;
			end
			S_CHK: begin
				if (sw == 0 || xpos + $signed({6'd0, sw}) <= 0 || xpos >= 13'sd288) st <= S_NEXT;
				else begin
					dxs <= zstep(gw32, sw); dys <= zstep(gw32, sh);
					st <= S_ROW;
				end
			end
			S_ROW: begin
				// the row's bursts: 4 for 32 wide, 2 for a 16-wide quarter
				nreq <= 0; nrx <= 0;
				s_req <= 1'b1; s_addr <= {mh && w6[0], sprn, row, qx[4:3]};
				st <= S_FETCH;
			end
			S_FETCH: if (s_ack) begin
				if (nreq + 1'd1 == (is32 ? 3'd4 : 3'd2)) begin s_req <= 1'b0; st <= S_WAIT; end
				else s_addr <= s_addr + 1'd1;
				nreq <= nreq + 1'd1;
			end
			S_WAIT: if (nrx == (is32 ? 3'd4 : 3'd2)) begin j <= 0; st <= S_DRAW; end
			S_DRAW: begin
				if (xs >= 0 && xs < 14'sd288 && pen != 8'hff) begin
					lb_we <= 1'b1; lb_x <= xs[8:0];
					lb_d  <= {1'b1, spri, scol, pen};
				end
				if (j + 1'd1 == sw) st <= S_NEXT;
				j <= j + 1'd1;
			end
			S_NEXT: begin
				if (n == 7'd127) begin busy <= 1'b0; st <= S_IDLE; end
				else begin n <= n + 1'd1; st <= S_W0; end
			end
			default: st <= S_IDLE;
		endcase
		// the row's bursts, in order: 8 pixels each (obj_layout, or raw bytes)
		if (!reset && s_valid) begin
			for (b = 0; b < 8; b = b + 1)
				row_pix[{nrx[1:0], b[2:0]}] <= mh ? s_data[8 * b +: 8] : opix(s_data[32 * b[2] +: 32], b[1:0]);
			nrx <= nrx + 1'd1;
		end
	end
endmodule
