// ROZ (A) (namcos2_roz.cpp draw_roz; tools/ns2_model.py roz_layer is the
// specification): renders one line of the ROZ plane into its own line buffer.
// The mixer resolves it against the tilemaps: MAME draws it after every plane
// of its priority or lower, so it wins over those and loses to higher ones.
//
//   start = ((startx << 4) + 38 * incxx) << 8, likewise y with incxy
//   src   = start + x * incx + y * incy (32-bit), pos = src >> 16
//   ctl[7] 0x4488 / 0x44cc: no wrap, 2048 x 2048; 0x44ee: no wrap, 256 x 256;
//   otherwise wrap at 2048. Without wrap a pixel is inside when
//   xpos <= size and ypos < size (MAME's comparisons).
//   tile code = rozram[(ypos >> 3) * 256 + (xpos >> 3)], pen 0xff transparent
module ns2_roz (
	input             clk,
	input             reset,
	input             start,
	input      [7:0]  y,
	output reg        busy,
	input      [127:0] ctl,         // the 8 control words
	// ROZ RAM, video port: data one clock after the address
	output reg [15:0] rr_addr,
	input      [15:0] rr_data,
	// ROZ ROM: 64-bit bursts (8 pixels), burst = code * 8 + row; in-order responses
	output reg        r_req,
	output reg [18:0] r_addr,
	input             r_ack,
	input             r_valid,
	input      [63:0] r_data,
	// ROZ line buffer: {valid, pen}
	output reg        lb_we,
	output reg [8:0]  lb_x,
	output reg [8:0]  lb_d
);
	function signed [31:0] s16(input [15:0] v);
		s16 = {{16{v[15]}}, v};
	endfunction
	wire [15:0] c0 = ctl[0 +: 16], c1 = ctl[16 +: 16], c2 = ctl[32 +: 16], c3 = ctl[48 +: 16];
	wire [15:0] c4 = ctl[64 +: 16], c5 = ctl[80 +: 16], c7 = ctl[112 +: 16];
	wire signed [31:0] incxx = s16(c0) <<< 8, incxy = s16(c1) <<< 8;
	wire signed [31:0] incyx = s16(c2) <<< 8, incyy = s16(c3) <<< 8;
	wire signed [31:0] startx = ((s16(c4) <<< 4) + 38 * s16(c0)) <<< 8;
	wire signed [31:0] starty = ((s16(c5) <<< 4) + 38 * s16(c1)) <<< 8;
	wire        nowrap = c7 == 16'h4488 || c7 == 16'h44cc || c7 == 16'h44ee;
	wire [11:0] size   = c7 == 16'h44ee ? 12'd256 : 12'd2048;

	// the pixel pipeline, which never freezes with a map read in flight:
	//   p1: the position, the map address issued; p2: the RAM's latency;
	//   then the code joins the pixel in FIFO A. The fetch side pops A,
	//   issues the burst and keeps x and the column in FIFO B until the data
	//   returns. The front only issues while A has room for the two in flight.
	reg  [31:0] ax, ay, dxx, dxy;
	reg  [8:0]  x;
	reg         wrap_l;
	reg  [11:0] size_l;
	localparam S_IDLE = 0, S_SETUP = 1, S_RUN = 2, S_DRAIN = 3;
	reg  [1:0]  st;

	wire [15:0] xp = ax[31:16], yp = ay[31:16];
	wire        in_plane = wrap_l ? 1'b1 : (xp <= size_l && yp < size_l);
	wire [10:0] xq = wrap_l ? xp[10:0] : (xp > 16'd2047 ? 11'd2047 : xp[10:0]);
	wire [10:0] yq = wrap_l ? yp[10:0] : (yp > 16'd2047 ? 11'd2047 : yp[10:0]);

	reg         p1_v, p2_v, p1_in, p2_in;
	reg  [8:0]  p1_x, p2_x;
	reg  [2:0]  p1_c, p2_c, p1_r, p2_r;
	// FIFO A: {x, column, row, code}
	// (the small queues are logic: a whole M10K each otherwise)
	(* ramstyle = "logic" *) reg  [8:0]  ax_q [0:15];
	(* ramstyle = "logic" *) reg  [2:0]  ac_q [0:15];
	(* ramstyle = "logic" *) reg  [2:0]  ar_q [0:15];
	(* ramstyle = "logic" *) reg  [15:0] ak_q [0:15];
	reg  [3:0]  aw, ar;
	reg  [4:0]  acnt;
	// FIFO B: {x, column} of the issued bursts
	(* ramstyle = "logic" *) reg  [8:0]  bx_q [0:15];
	(* ramstyle = "logic" *) reg  [2:0]  bc_q [0:15];
	reg  [3:0]  bw, br;
	reg  [4:0]  bcnt;

	wire push_a = p2_v && p2_in;
	wire issue  = st == S_RUN && acnt + {4'd0, p1_v} + {4'd0, p2_v} < 5'd14;
	wire pop_a  = acnt != 0 && (!r_req || r_ack) && bcnt < 5'd14;

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; r_req <= 1'b0;
			p1_v <= 1'b0; p2_v <= 1'b0; aw <= 0; ar <= 0; acnt <= 0; bw <= 0; br <= 0; bcnt <= 0;
		end else begin
			case (st)
				S_IDLE: if (start) begin busy <= 1'b1; st <= S_SETUP; end
				S_SETUP: begin
					ax <= startx + $signed({1'b0, y}) * incyx;
					ay <= starty + $signed({1'b0, y}) * incyy;
					dxx <= incxx; dxy <= incxy;
					wrap_l <= !nowrap; size_l <= size;
					x <= 0;
					st <= S_RUN;
				end
				S_RUN: if (issue && x == 9'd287) st <= S_DRAIN;
				S_DRAIN: if (!p1_v && !p2_v && acnt == 0 && !r_req && bcnt == 0) begin
					busy <= 1'b0; st <= S_IDLE;
				end
			endcase
			// p1: issue the map read
			p1_v <= issue;
			if (issue) begin
				p1_in <= in_plane; p1_x <= x; p1_c <= xq[2:0]; p1_r <= yq[2:0];
				rr_addr <= {yq[10:3], xq[10:3]};
				ax <= ax + dxx; ay <= ay + dxy;
				x <= x + 1'd1;
			end
			// p2: the RAM's latency
			p2_v <= p1_v; p2_in <= p1_in; p2_x <= p1_x; p2_c <= p1_c; p2_r <= p1_r;
			// the code is in: FIFO A (a pixel outside the plane is simply not drawn)
			if (push_a) begin
				ax_q[aw] <= p2_x; ac_q[aw] <= p2_c; ar_q[aw] <= p2_r; ak_q[aw] <= rr_data;
				aw <= aw + 1'd1;
			end
			// the fetch side
			if (pop_a) begin
				r_req <= 1'b1; r_addr <= {ak_q[ar], ar_q[ar]};
				bx_q[bw] <= ax_q[ar]; bc_q[bw] <= ac_q[ar]; bw <= bw + 1'd1;
				ar <= ar + 1'd1;
			end else if (r_ack) r_req <= 1'b0;
			acnt <= acnt + {4'd0, push_a} - {4'd0, pop_a};
			// the data: FIFO B
			if (r_valid) begin
				lb_we <= 1'b1; lb_x <= bx_q[br];
				lb_d  <= {r_data[8 * bc_q[br] +: 8] != 8'hff, r_data[8 * bc_q[br] +: 8]};
				br <= br + 1'd1;
			end
			bcnt <= bcnt + {4'd0, pop_a} - {4'd0, r_valid};
		end
	end
endmodule
