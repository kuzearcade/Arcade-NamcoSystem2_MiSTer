// C355 sprites (namco_c355spr.cpp; tools/ns2_c355hw.py is the specification,
// proven equal to MAME's frame algorithm, tools/ns2_model.py sprites_c355).
//
// A per-frame pass (from `prep`, in vblank) walks the list (0x1000 + i, to
// bit 8) and condenses each entry into a record: position (after the format's
// offset, zoomed), size, rows and columns (q, rem of the size over them),
// flips, priority, colour, tile index and offset, the window, and the lines
// it can touch. Per line (`start`), the records in list order: the rows whose
// tiles cover the line (row r of n over V pixels starts at r*q + max(0, r -
// (n - rem)), zoom q*4096 + (min(rem, n-r)*4096)/(n-r)), then each column's
// tile: its row of 16 pixels (two bursts), drawn zoomed into the sprite line
// buffer inside the entry's window; later tiles overwrite earlier ones.
// C355 RAM (word offsets): 0x0000 the table (8 words an entry), 0x1000 the
// list, 0x1200 the windows (4 words), 0x2000 the formats (4 words), 0x4000
// the tiles; the CPU sees 0xa100 words, beyond reads 0.
module ns2_c355 (
	input             clk,
	input             reset,
	input             prep,          // build the records (vblank)
	input             start,         // render line y
	input      [7:0]  y,
	output            busy,
	input      [15:0] pos0, pos1,    // the position registers (y, x scroll)
	// C355 RAM, video port: data one clock after the address
	output     [15:0] cr_addr,
	input      [15:0] cr_data,
	// sprite ROM (gfx_16x16x8_raw): 64-bit bursts, burst = tile * 32 + row * 2 + half
	output reg        s_req,
	output reg [18:0] s_addr,
	input             s_ack,
	input             s_valid,
	input      [63:0] s_data,
	// the sprite line buffer: {valid, pri[3:0], colour[11:0]}, two adjacent
	// pixels a clock (x and x + 1; the buffer is split by x & 1)
	output reg        lb_we,
	output reg [8:0]  lb_x,
	output reg [16:0] lb_d,
	output reg        lb_we2,
	output reg [8:0]  lb_x2,
	output reg [16:0] lb_d2
);
	// (k * 4096) / l, k <= l <= 16: the rows' and columns' zoom fractions
	function [12:0] zt(input [4:0] l, input [4:0] k);
		reg [16:0] n;             // k * 4096 needs 17 bits (13 would overflow)
		begin
			n = {12'd0, k} << 12;
			zt = l == 0 ? 13'd0 : n / {12'd0, l};
		end
	endfunction
	// (16 << 16) / n for a tile's screen size n (1..1023)
	function [20:0] zstep(input [9:0] n);
		zstep = n == 0 ? 21'd0 : 21'h100000 / {11'd0, n};
	endfunction
	function signed [12:0] sx11(input [10:0] v);
		sx11 = {{2{v[10]}}, v};
	endfunction
	function signed [12:0] sx9(input [15:0] v);
		sx9 = {{4{v[8]}}, v[8:0]};
	endfunction

	// ------------------------------------------------------------ records
	reg        r_v    [0:255] /*verilator public_flat_rw*/;
	reg [3:0]  r_pri  [0:255] /*verilator public_flat_rw*/, r_col [0:255] /*verilator public_flat_rw*/;
	reg        r_fx   [0:255] /*verilator public_flat_rw*/, r_fy  [0:255] /*verilator public_flat_rw*/;
	reg [9:0]  r_h    [0:255] /*verilator public_flat_rw*/, r_vv  [0:255] /*verilator public_flat_rw*/;
	reg [4:0]  r_nc   [0:255] /*verilator public_flat_rw*/, r_nr  [0:255] /*verilator public_flat_rw*/;
	reg [9:0]  r_qx   [0:255] /*verilator public_flat_rw*/, r_qy  [0:255] /*verilator public_flat_rw*/;
	reg [3:0]  r_rx   [0:255] /*verilator public_flat_rw*/, r_ry  [0:255] /*verilator public_flat_rw*/;
	reg signed [12:0] r_hp [0:255] /*verilator public_flat_rw*/, r_vp [0:255] /*verilator public_flat_rw*/;
	reg [15:0] r_tile [0:255] /*verilator public_flat_rw*/, r_off [0:255] /*verilator public_flat_rw*/;
	reg signed [17:0] r_cx0 [0:255] /*verilator public_flat_rw*/, r_cx1 [0:255] /*verilator public_flat_rw*/, r_cy0 [0:255] /*verilator public_flat_rw*/, r_cy1 [0:255] /*verilator public_flat_rw*/;
	reg signed [12:0] r_ymin [0:255] /*verilator public_flat_rw*/, r_ymax [0:255] /*verilator public_flat_rw*/;
	reg [8:0]  nrec /*verilator public_flat_rw*/;
	reg [15:0] p_cr, l_cr;        // the pass's and the line's reads (never at once)
	integer k;
	initial l_cr = 0;

	// ------------------------------------------------------------ the pass
	// 17 reads an entry (the list word, 8 table words, 4 window words, 4
	// format words: each address depends on an earlier word), two small
	// divisions (width / columns, height / rows), the format's offset, the
	// lines the rows' tiles cover
	localparam P_IDLE = 0, P_ISSUE = 1, P_WAIT = 2, P_CAP = 3, P_DIV = 4, P_ADJ = 5, P_OFF = 6, P_SPAN = 7, P_STORE = 8;
	reg [3:0]  ps;
	reg [8:0]  pi;
	reg [4:0]  pk;               // the word being read (0..16)
	reg [15:0] w [0:16];         // 0 list, 1..8 table, 9..12 window, 13..16 format
	reg        dy_pass;          // the division: 0 columns, 1 rows
	reg [3:0]  di;
	reg [9:0]  dq, dr;
	reg [9:0]  qx, qy;
	reg [3:0]  rx, ry;
	reg [4:0]  sr;
	reg signed [12:0] ymin, ymax, hp, vp;
	wire signed [12:0] xscroll = sx9(pos1) + 13'sd38, yscroll = sx9(pos0) + 13'sd25;
	wire [15:0] which = w[0];
	wire [15:0] tb0 = w[1], tb1 = w[2], tb2 = w[3], tb3 = w[4], tb4 = w[5], tb5 = w[6], tb6 = w[7];
	wire [4:0]  f_nc = w[14][7:4] == 0 ? 5'd16 : {1'b0, w[14][7:4]};
	wire [4:0]  f_nr = w[14][3:0] == 0 ? 5'd16 : {1'b0, w[14][3:0]};
	wire [9:0]  f_h  = tb4[9:0], f_v = tb5[9:0];
	wire [15:0] p_addr = pk == 0 ? 16'h1000 + {7'd0, pi} :
	                     pk <= 5'd8  ? {5'd0, which[7:0], 3'd0} + {11'd0, pk - 5'd1} :
	                     pk <= 5'd12 ? 16'h1200 + {10'd0, tb6[11:8], 2'd0} + {11'd0, pk - 5'd9} :
	                                   16'h2000 + {3'd0, tb0[10:0], 2'd0} + {11'd0, pk - 5'd13};
	// the format's offset, zoomed: ((d & 0xff) * zoom + 0x8000) >> 16, zoom = q*4096 + zt
	wire [21:0] zx   = {qx, 12'd0} + zt(f_nc, {1'b0, rx});
	wire [21:0] zy   = {qy, 12'd0} + zt(f_nr, {1'b0, ry});
	wire [29:0] dxzp = w[15][7:0] * zx + 30'h8000;
	wire [29:0] dyzp = w[16][7:0] * zy + 30'h8000;
	wire signed [12:0] dxz = w[15][8] ? -$signed({1'b0, dxzp[27:16]}) : $signed({1'b0, dxzp[27:16]});
	wire signed [12:0] dyz = w[16][8] ? -$signed({1'b0, dyzp[27:16]}) : $signed({1'b0, dyzp[27:16]});
	// row sr of the span: its top and its tiles' height
	wire [4:0]  sp_left = f_nr - sr;
	wire [4:0]  sp_k    = sp_left < {1'b0, ry} ? sp_left : {1'b0, ry};
	wire [9:0]  sp_st   = sr * qy + (sr > f_nr - ry ? {5'd0, sr - (f_nr - ry)} : 10'd0);
	wire [9:0]  sp_th   = qy + (sr >= f_nr - ry ? 10'd1 : 10'd0);
	wire [21:0] sp_zoom = {qy, 12'd0} + zt(sp_left, sp_k);
	wire [9:0]  sp_sh   = (sp_zoom + 22'd2048) >> 12;
	wire signed [12:0] sp_top = tb5[15] ? vp - $signed({3'd0, sp_st}) - $signed({3'd0, sp_th}) : vp + $signed({3'd0, sp_st});
	wire signed [12:0] sp_bot = sp_top + $signed({3'd0, sp_sh});

	always @(posedge clk) begin
		if (reset) begin ps <= P_IDLE; nrec <= 0; end
		else case (ps)
			P_IDLE: if (prep) begin pi <= 0; nrec <= 0; pk <= 0; ps <= P_ISSUE; end
			P_ISSUE: begin p_cr <= p_addr; ps <= P_WAIT; end
			P_WAIT: ps <= P_CAP;
			P_CAP: begin
				w[pk] <= cr_data;
				if (pk == 5'd16) begin dy_pass <= 1'b0; di <= 0; ps <= P_DIV; end
				else begin pk <= pk + 1'd1; ps <= P_ISSUE; end
			end
			P_DIV: begin
				// restoring division of a 10-bit size by 1..16, 10 steps
				if (di == 0) begin
					dq <= dy_pass ? f_v : f_h; dr <= 0; di <= 1;
				end else begin
					if ({dr[8:0], dq[9]} >= {5'd0, dy_pass ? f_nr : f_nc}) begin
						dr <= {dr[8:0], dq[9]} - {5'd0, dy_pass ? f_nr : f_nc}; dq <= {dq[8:0], 1'b1};
					end else begin
						dr <= {dr[8:0], dq[9]}; dq <= {dq[8:0], 1'b0};
					end
					di <= di + 1'd1;
				end
				if (di == 4'd11) begin
					if (!dy_pass) begin qx <= dq; rx <= dr[3:0]; dy_pass <= 1'b1; di <= 0; end
					else begin qy <= dq; ry <= dr[3:0]; ps <= P_ADJ; end
				end
			end
			P_ADJ: begin
				hp <= sx11(tb2[10:0] - xscroll[10:0]); vp <= sx11(tb3[10:0] - yscroll[10:0]);
				ps <= P_OFF;
			end
			P_OFF: begin
				// the format's offset (qx, qy are in now)
				hp <= tb4[15] ? hp + dxz : hp - dxz;
				vp <= tb5[15] ? vp + dyz : vp - dyz;
				ymin <= 13'sd4095; ymax <= -13'sd4096;
				sr <= 0; ps <= P_SPAN;
			end
			P_SPAN: begin
				// the lines each row's tiles cover: [top, top + sh)
				if (sp_top < ymin) ymin <= sp_top;
				if (sp_bot > ymax) ymax <= sp_bot;
				if (sr + 1'd1 == f_nr) ps <= P_STORE;
				sr <= sr + 1'd1;
			end
			P_STORE: begin
				r_v[pi]   <= f_h != 0 && f_v != 0;
				r_pri[pi] <= tb6[7:4]; r_col[pi] <= tb6[3:0];
				r_fx[pi]  <= tb4[15]; r_fy[pi] <= tb5[15];
				r_h[pi]   <= f_h; r_vv[pi] <= f_v;
				r_nc[pi]  <= f_nc; r_nr[pi] <= f_nr;
				r_qx[pi]  <= qx; r_rx[pi] <= rx; r_qy[pi] <= qy; r_ry[pi] <= ry;
				r_hp[pi]  <= hp; r_vp[pi] <= vp;
				r_tile[pi] <= w[13]; r_off[pi] <= tb1;
				r_cx0[pi] <= $signed({2'd0, w[9]})  - xscroll; r_cx1[pi] <= $signed({2'd0, w[10]}) - xscroll;
				r_cy0[pi] <= $signed({2'd0, w[11]}) - yscroll; r_cy1[pi] <= $signed({2'd0, w[12]}) - yscroll;
				r_ymin[pi] <= ymin; r_ymax[pi] <= ymax;
				nrec <= pi + 1'd1;
				if (which[8] || pi == 9'd255) ps <= P_IDLE;
				else begin pi <= pi + 1'd1; pk <= 0; ps <= P_ISSUE; end
			end
			default: ps <= P_IDLE;
		endcase
	end

	// ------------------------------------------------------------ a line
	// Three parts, so a busy line (hundreds of tile columns, 12 x overdraw)
	// fits: the walker finds the line's tile columns (records, rows, columns)
	// at a column a clock, its tile-word reads pipelined; each drawable column
	// becomes a job (FIFO of 8, with room kept for the reads in flight); the
	// fetcher issues each job's two bursts; the drawer draws the oldest job
	// whose 16 pixels are in, two pixels a clock.
	localparam L_IDLE = 0, L_REC = 1, L_CHK = 2, L_ROW = 3, L_COL = 4, L_DRAIN = 5, L_DONE = 6;
	reg [2:0]  ls;
	reg [7:0]  yl;
	reg [8:0]  li;
	// the record being walked (a registered read of the record arrays)
	reg        c_v, c_fx, c_fy;
	reg [3:0]  c_pri, c_col, c_rx, c_ry;
	reg [9:0]  c_h, c_vv, c_qx, c_qy;
	reg [4:0]  c_nc, c_nr;
	reg signed [12:0] c_hp, c_vp, c_ymin, c_ymax;
	reg [15:0] c_tile, c_off;
	reg signed [17:0] c_cx0, c_cx1, c_cy0, c_cy1;
	reg [4:0]  rr, cc;
	reg [3:0]  srow;

	// row rr: top, tiles' height
	wire [4:0]  rw_left = c_nr - rr;
	wire [4:0]  rw_k    = rw_left < {1'b0, c_ry} ? rw_left : {1'b0, c_ry};
	wire [9:0]  rw_st   = rr * c_qy + (rr > c_nr - c_ry ? {5'd0, rr - (c_nr - c_ry)} : 10'd0);
	wire [9:0]  rw_th   = c_qy + (rr >= c_nr - c_ry ? 10'd1 : 10'd0);
	wire [21:0] rw_zoom = {c_qy, 12'd0} + zt(rw_left, rw_k);
	wire [9:0]  rw_sh   = (rw_zoom + 22'd2048) >> 12;
	wire signed [12:0] rw_top = c_fy ? c_vp - $signed({3'd0, rw_st}) - $signed({3'd0, rw_th}) : c_vp + $signed({3'd0, rw_st});
	wire signed [12:0] yy   = $signed({5'd0, yl});
	wire [9:0]  rw_i    = yy - rw_top;
	wire [20:0] rw_ddy  = zstep(rw_sh);
	wire [30:0] rw_srcp = (c_fy ? rw_sh - 10'd1 - rw_i : rw_i) * rw_ddy;
	// column cc: left, width, its tile word's index
	wire [4:0]  cl_left = c_nc - cc;
	wire [4:0]  cl_k    = cl_left < {1'b0, c_rx} ? cl_left : {1'b0, c_rx};
	wire [9:0]  cl_st   = cc * c_qx + (cc > c_nc - c_rx ? {5'd0, cc - (c_nc - c_rx)} : 10'd0);
	wire [9:0]  cl_tw   = c_qx + (cc >= c_nc - c_rx ? 10'd1 : 10'd0);
	wire [21:0] cl_zoom = {c_qx, 12'd0} + zt(cl_left, cl_k);
	wire [9:0]  cl_sw   = (cl_zoom + 22'd2048) >> 12;
	wire signed [12:0] cl_x = c_fx ? c_hp - $signed({3'd0, cl_st}) - $signed({3'd0, cl_tw}) : c_hp + $signed({3'd0, cl_st});
	wire [15:0] cl_ti   = c_tile + {7'd0, {4'd0, rr} * {4'd0, c_nc}} + {11'd0, cc};   // (9-bit product)
	// (a concatenation is unsigned: sign-extended into signed wires first)
	wire signed [17:0] cl_x18 = {{5{cl_x[12]}}, cl_x};
	wire signed [17:0] cl_r18 = cl_x18 + $signed({8'd0, cl_sw});
	// a column worth drawing: on screen and inside the window
	wire        cl_on   = cl_sw != 0 && cl_x18 <= c_cx1 && cl_r18 > c_cx0 && cl_x18 <= 18'sd287 && cl_r18 > 18'sd0;

	// the tile-word reads in flight: two stages (the RAM's latency)
	reg        t1_v, t2_v, t1_beyond, t2_beyond;
	reg signed [12:0] t1_left, t2_left;
	reg [9:0]  t1_sw, t2_sw;
	reg [3:0]  t1_srow, t2_srow;
	reg        t1_fx, t2_fx;
	reg [3:0]  t1_pri, t2_pri, t1_col, t2_col;
	reg signed [17:0] t1_cx0, t2_cx0, t1_cx1, t2_cx1;
	reg [15:0] t1_off, t2_off;

	// the jobs (8): geometry, the burst address, the pixels
	reg signed [12:0] j_left [0:7];
	reg [9:0]  j_sw  [0:7];
	reg [20:0] j_ddx [0:7];
	reg        j_fx  [0:7];
	reg [3:0]  j_pri [0:7], j_col [0:7];
	reg signed [17:0] j_cx0 [0:7], j_cx1 [0:7];
	reg [18:0] j_addr [0:7];
	reg [7:0]  j_pix [0:7][0:15];
	reg [2:0]  jw, jf, jd, jr;      // write, fetch, data (returns), draw pointers
	reg [3:0]  jcnt, jfn, jdn;      // jobs queued; queued but not fetched; fetched, data in, not drawn
	reg        fhalf, rhalf;
	// the drawer
	reg [9:0]  j;
	wire [9:0]  sw_r = j_sw[jr];
	wire [20:0] dd_r = j_ddx[jr];
	wire signed [12:0] px_x  = j_left[jr] + $signed({3'd0, j});
	wire signed [12:0] px_x2 = px_x + 13'sd1;
	wire signed [17:0] px_18  = {{5{px_x[12]}}, px_x};
	wire signed [17:0] px2_18 = {{5{px_x2[12]}}, px_x2};
	wire [30:0] px_p  = (j_fx[jr] ? sw_r - 10'd1 - j : j) * dd_r;
	wire [30:0] px_p2 = (j_fx[jr] ? sw_r - 10'd2 - j : j + 10'd1) * dd_r;
	wire [7:0]  pen   = j_pix[jr][px_p[19:16]];
	wire [7:0]  pen2  = j_pix[jr][px_p2[19:16]];
	wire        two   = j + 10'd1 < sw_r;
	wire        drawing = jdn != 0;
	wire        pop   = drawing && (j + 10'd2 >= sw_r);
	wire        push  = t2_v && !(!t2_beyond && cr_data[15]);
	// the walker issues a column only while the queue has room for it and
	// the two reads ahead of it
	wire        room  = jcnt + {3'd0, t1_v} + {3'd0, t2_v} < 4'd7;

	assign busy = ls != L_IDLE;
	assign cr_addr = ps != P_IDLE ? p_cr : l_cr;

	always @(posedge clk) begin
		lb_we <= 1'b0; lb_we2 <= 1'b0;
		if (reset) begin
			ls <= L_IDLE; s_req <= 1'b0; t1_v <= 1'b0; t2_v <= 1'b0;
			jw <= 0; jf <= 0; jd <= 0; jr <= 0; jcnt <= 0; jfn <= 0; jdn <= 0; fhalf <= 0; rhalf <= 0; j <= 0;
		end else begin
			t1_v <= 1'b0;
			case (ls)
				L_IDLE: if (start) begin yl <= y; li <= 0; ls <= L_REC; end
				L_REC: begin
					if (li == nrec) ls <= L_DRAIN;
					else begin
						c_v <= r_v[li]; c_fx <= r_fx[li]; c_fy <= r_fy[li];
						c_pri <= r_pri[li]; c_col <= r_col[li]; c_rx <= r_rx[li]; c_ry <= r_ry[li];
						c_h <= r_h[li]; c_vv <= r_vv[li]; c_qx <= r_qx[li]; c_qy <= r_qy[li];
						c_nc <= r_nc[li]; c_nr <= r_nr[li];
						c_hp <= r_hp[li]; c_vp <= r_vp[li]; c_ymin <= r_ymin[li]; c_ymax <= r_ymax[li];
						c_tile <= r_tile[li]; c_off <= r_off[li];
						c_cx0 <= r_cx0[li]; c_cx1 <= r_cx1[li]; c_cy0 <= r_cy0[li]; c_cy1 <= r_cy1[li];
						ls <= L_CHK;
					end
				end
				L_CHK: begin
					if (!c_v || $signed({10'd0, yl}) < c_cy0 || $signed({10'd0, yl}) > c_cy1 || yy < c_ymin || yy >= c_ymax) begin
						li <= li + 1'd1; ls <= L_REC;
					end else begin rr <= 0; ls <= L_ROW; end
				end
				L_ROW: begin
					// does row rr's tile cover this line?
					if (rw_sh != 0 && yy >= rw_top && yy < rw_top + $signed({3'd0, rw_sh})) begin
						srow <= rw_srcp[19:16]; cc <= 0; ls <= L_COL;
					end else if (rr + 1'd1 == c_nr) begin li <= li + 1'd1; ls <= L_REC; end
					else rr <= rr + 1'd1;
				end
				L_COL: if (room) begin
					// a column a clock: its tile word is read if it can be drawn
					if (cl_on) begin
						t1_v <= 1'b1;
						l_cr <= cl_ti < 16'h6100 ? 16'h4000 + cl_ti : 16'h0000;
						t1_beyond <= cl_ti >= 16'h6100;    // beyond the CPU's window: tile 0, drawn
						t1_left <= cl_x; t1_sw <= cl_sw; t1_srow <= srow; t1_fx <= c_fx;
						t1_pri <= c_pri; t1_col <= c_col; t1_cx0 <= c_cx0; t1_cx1 <= c_cx1; t1_off <= c_off;
					end
					if (cc + 1'd1 == c_nc) begin
						// the next row may cover this line too (a zoomed tile overlaps)
						if (rr + 1'd1 == c_nr) begin li <= li + 1'd1; ls <= L_REC; end
						else begin rr <= rr + 1'd1; ls <= L_ROW; end
					end else cc <= cc + 1'd1;
				end
				L_DRAIN: if (!t1_v && !t2_v && jcnt == 0 && !s_req) ls <= L_IDLE;
				default: ls <= L_IDLE;
			endcase
			// the tile word's latency, then the job
			t2_v <= t1_v; t2_beyond <= t1_beyond; t2_left <= t1_left; t2_sw <= t1_sw; t2_srow <= t1_srow; t2_fx <= t1_fx;
			t2_pri <= t1_pri; t2_col <= t1_col; t2_cx0 <= t1_cx0; t2_cx1 <= t1_cx1; t2_off <= t1_off;
			if (push) begin
				j_left[jw] <= t2_left; j_sw[jw] <= t2_sw; j_ddx[jw] <= zstep(t2_sw); j_fx[jw] <= t2_fx;
				j_pri[jw] <= t2_pri; j_col[jw] <= t2_col; j_cx0[jw] <= t2_cx0; j_cx1[jw] <= t2_cx1;
				j_addr[jw] <= {(((t2_beyond ? 16'h0000 : cr_data) + t2_off) & 16'h3fff), t2_srow, 1'b0};
				jw <= jw + 1'd1;
			end
			// the fetcher: each job's two bursts, in order
			if (s_req && s_ack) begin
				if (fhalf) begin s_req <= 1'b0; jf <= jf + 1'd1; end
				else s_addr <= s_addr + 1'd1;
				fhalf <= !fhalf;
			end else if (!s_req && jfn != 0) begin
				s_req <= 1'b1; s_addr <= j_addr[jf]; fhalf <= 1'b0;
			end
			// the returns
			if (s_valid) begin
				for (k = 0; k < 8; k = k + 1) j_pix[jd][{rhalf, k[2:0]}] <= s_data[8 * k +: 8];
				rhalf <= !rhalf;
				if (rhalf) jd <= jd + 1'd1;
			end
			// the drawer: two pixels a clock
			if (drawing) begin
				if (px_18 >= j_cx0[jr] && px_18 <= j_cx1[jr] && px_x >= 0 && px_x < 13'sd288 && pen != 8'hff) begin
					lb_we <= 1'b1; lb_x <= px_x[8:0]; lb_d <= {1'b1, j_pri[jr], j_col[jr], pen};
				end
				if (two && px2_18 >= j_cx0[jr] && px2_18 <= j_cx1[jr] && px_x2 >= 0 && px_x2 < 13'sd288 && pen2 != 8'hff) begin
					lb_we2 <= 1'b1; lb_x2 <= px_x2[8:0]; lb_d2 <= {1'b1, j_pri[jr], j_col[jr], pen2};
				end
				if (pop) begin j <= 0; jr <= jr + 1'd1; end
				else j <= j + 10'd2;
			end
			jcnt <= jcnt + {3'd0, push} - {3'd0, pop};
			jfn  <= jfn + {3'd0, push} - {3'd0, s_req && s_ack && fhalf};
			jdn  <= jdn + {3'd0, s_valid && rhalf} - {3'd0, pop};
		end
	end
endmodule
