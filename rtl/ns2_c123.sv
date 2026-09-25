// C123 tilemaps (namco_c123tmap.cpp; tools/ns2_model.py tilemap_layer is the
// specification): renders one line of the six planes into the composition
// line buffer, in MAME's draw order (priority 0..7, then plane 0..5), each
// opaque pixel overwriting what an earlier plane wrote.
//
// Per plane: fetch the line's tile slots (the tile code from tilemap RAM, the
// tile row's 8 pixels and the tile's mask row), then write 288 pixels.
//   planes 0-3: 64x64 tiles, scroll x + dx (44 + 4/2/1/0), scroll y + 24
//   planes 4-5: 36x28 tiles at words 0x4008 / 0x4408, no scroll
//   flip (ctl[1] bit 15) mirrors both
// A slot is a column of 8 screen pixels u .. u+7 of u = x + scroll + dx.
module ns2_c123 (
	input             clk,
	input             reset,
	input             start,         // render line y
	input      [7:0]  y,
	output reg        busy,
	input      [511:0] ctl,          // the 32 control words, word k at [16k +: 16]
	input             tile_fl2,      // finalap2 / finalap3: TilemapCB_finalap2
	// tilemap RAM, video port: data one clock after the address
	output reg [14:0] vr_addr,
	input      [15:0] vr_data,
	// tile ROM: 64-bit bursts (8 pixels), burst = tile * 8 + row; in-order responses
	output reg        t_req,
	output reg [18:0] t_addr,
	input             t_ack,
	input             t_valid,
	input      [63:0] t_data,
	// mask ROM: bytes, byte = code * 8 + row, bit 7 = leftmost pixel
	output reg        m_req,
	output reg [18:0] m_addr,
	input             m_ack,
	input             m_valid,
	input      [7:0]  m_data,
	// composition line buffer: {valid, pri[2:0], colour[12:0]}
	output reg        lb_we,
	output reg [8:0]  lb_x,
	output reg [16:0] lb_d
);
	function [15:0] cw(input integer k);
		cw = ctl[16 * k +: 16];
	endfunction

	// TilemapCB: bitswap<16>(code, 13,12,11,15,14,10..0);
	// TilemapCB_finalap2: bitswap<15>(code, 13,12,11,14,10..0)
	function [15:0] tile_cb(input [15:0] c);
		tile_cb = tile_fl2 ? {1'b0, c[13], c[12], c[11], c[14], c[10:0]}
		                   : {c[13], c[12], c[11], c[15], c[14], c[10:0]};
	endfunction

	// The planes in MAME's draw order (priority 0..7, then plane 0..5) are
	// listed first; then a fetch engine fills slot bank k & 1 for the k-th
	// listed plane while the pixel engine draws the plane before it from the
	// other bank: a line costs about six times the larger of a plane's fetch
	// and its 288 pixels, not their sum.
	localparam S_IDLE = 0, S_LIST = 1, S_RUN = 2;
	reg [1:0]  st;
	reg [2:0]  lp;             // listing: priority
	reg [2:0]  li;             // listing: plane
	reg [2:0]  ord [0:5];      // the planes to draw, in order
	reg [2:0]  opri [0:5];     // and their priorities
	reg [2:0]  n;              // how many
	reg [7:0]  yl;

	// ------------------------------------------------------------ fetch
	localparam F_IDLE = 0, F_SETUP = 1, F_ADDR = 2, F_CODE = 3, F_REQ = 4, F_WAIT = 5, F_DONE = 6,
	           F_PARAM = 7, F_FILL = 8;
	reg [3:0]  fs;
	reg [2:0]  fk;             // the listed plane being fetched
	reg [2:0]  i;              // its number
	reg        flip, fixed;
	reg [9:0]  u0;
	reg [8:0]  ty;
	reg [5:0]  k, nslots;
	reg        t_done, m_done;
	// the banks: pixels, masks, and the plane's parameters
	reg [63:0] pix  [0:1][0:36];
	reg [7:0]  mask [0:1][0:36];
	reg        b_full [0:1];
	reg        b_flip [0:1];
	reg [2:0]  b_u0 [0:1];     // the scroll's fine part: pixel x is slot (x + u0) >> 3
	reg [12:0] b_colour [0:1];
	reg [2:0]  b_pri [0:1];
	reg [5:0]  b_n [0:1];
	reg [5:0]  t_rx, m_rx;     // the returns into the bank being fetched
	reg        fb;             // that bank

	wire [15:0] lctl  = cw(16 + i);      // priority, bit 3 = off
	wire [15:0] lctl_l = cw(16 + li);    // the plane being listed
	wire [15:0] lcol  = cw(24 + i);      // colour bank
	wire [15:0] ctl1  = cw(1);           // bit 15 = flip
	wire [8:0]  sx = cw(4 * i + 1) & 9'h1ff;
	wire [8:0]  sy = cw(4 * i + 3) & 9'h1ff;
	wire [5:0]  dx = i == 0 ? 6'd48 : i == 1 ? 6'd46 : i == 2 ? 6'd45 : 6'd44;
	wire [8:0]  ty_s = yl + sy + 9'd24;
	wire [6:0]  ku = u0[9:3] + k;
	wire [5:0]  mc = fixed ? (flip ? 6'd35 - k : k) : (flip ? 6'd63 - ku[5:0] : ku[5:0]);
	wire [14:0] map_addr = fixed ? (i == 4 ? 15'h4008 : 15'h4408) + ty[7:3] * 36 + mc
	                             : {i[1:0], ty[8:3], mc};

	// ------------------------------------------------------------ pixels
	reg        xs_run;
	reg [2:0]  xk;             // the listed plane being drawn
	reg        xb;             // its bank
	reg [8:0]  x;
	wire [9:0] xu  = x + b_u0[xb];
	wire [5:0] s   = xu[8:3];
	wire [2:0] col = b_flip[xb] ? 3'd7 - xu[2:0] : xu[2:0];
	wire [7:0] pen = pix[xb][s][8 * col +: 8];
	wire       op  = mask[xb][s][3'd7 - col];

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; t_req <= 1'b0; m_req <= 1'b0; fs <= F_IDLE; xs_run <= 1'b0;
			b_full[0] <= 1'b0; b_full[1] <= 1'b0;
		end else begin
			case (st)
				S_IDLE: if (start) begin
					yl <= y; lp <= 0; li <= 0; n <= 0; busy <= 1'b1; st <= S_LIST;
				end
				S_LIST: begin
					// one (priority, plane) pair a clock: 48 clocks
					if (lctl_l[2:0] == lp && !lctl_l[3]) begin
						ord[n] <= li; opri[n] <= lp; n <= n + 1'd1;
					end
					if (li == 5) begin
						li <= 0;
						if (lp == 7) begin
							st <= S_RUN; fk <= 0; xk <= 0; fs <= F_SETUP; xs_run <= 1'b0;
						end else lp <= lp + 1'd1;
					end else li <= li + 1'd1;
				end
				S_RUN: if (fs == F_DONE && xk == n) begin busy <= 1'b0; st <= S_IDLE; fs <= F_IDLE; end
				default: st <= S_IDLE;
			endcase

			// fetch: plane fk into bank fk & 1, once the pixel engine is done with it
			case (fs)
				F_SETUP: begin
					if (fk == n) fs <= F_DONE;
					else if (!b_full[fk[0]]) begin
						i <= ord[fk]; fb <= fk[0]; k <= 0; t_rx <= 0; m_rx <= 0;
						fs <= F_PARAM;   // the parameters, next clock (i is set now)
					end
				end
				F_PARAM: begin
					flip  <= ctl1[15];
					fixed <= i >= 4;
					if (i < 4) begin
						u0 <= sx + dx;
						ty <= ctl1[15] ? 9'd511 - ty_s : ty_s;
						nslots <= 6'd37;
					end else begin
						u0 <= 0;
						ty <= ctl1[15] ? 9'd223 - yl : {1'b0, yl};
						nslots <= 6'd36;
					end
					b_colour[fb] <= 13'h1000 | {2'b00, lcol[2:0], 8'h00};
					b_pri[fb] <= opri[fk];
					fs <= F_ADDR;
				end
				F_ADDR: begin vr_addr <= map_addr; fs <= F_CODE; end
				F_CODE: fs <= F_REQ;          // the RAM's latency
				F_REQ: begin
					t_req <= 1'b1; t_addr <= {tile_cb(vr_data), ty[2:0]};
					m_req <= 1'b1; m_addr <= {vr_data, ty[2:0]};
					t_done <= 1'b0; m_done <= 1'b0;
					fs <= F_WAIT;
				end
				F_WAIT: begin
					if (t_ack) begin t_req <= 1'b0; t_done <= 1'b1; end
					if (m_ack) begin m_req <= 1'b0; m_done <= 1'b1; end
					if ((t_done || t_ack) && (m_done || m_ack)) begin
						if (k + 1'd1 == nslots) begin
							// every slot requested: the bank fills as the data returns
							b_flip[fb] <= flip; b_u0[fb] <= u0[2:0]; b_n[fb] <= nslots;
							fk <= fk + 1'd1;
							fs <= F_FILL;   // wait for the returns
						end else begin k <= k + 1'd1; fs <= F_ADDR; end
					end
				end
				F_FILL: if (t_rx == nslots && m_rx == nslots) begin
					b_full[fb] <= 1'b1;
					fs <= F_SETUP;
				end
				default: ;
			endcase
			// the returns, in order, into the bank being fetched
			if (t_valid) begin pix[fb][t_rx] <= t_data; t_rx <= t_rx + 1'd1; end
			if (m_valid) begin mask[fb][m_rx] <= m_data; m_rx <= m_rx + 1'd1; end

			// pixels: plane xk from bank xk & 1, a pixel a clock
			if (st == S_RUN && xk != n) begin
				if (!xs_run) begin
					if (b_full[xk[0]]) begin xs_run <= 1'b1; xb <= xk[0]; x <= 0; end
				end else begin
					lb_we <= op; lb_x <= x; lb_d <= {1'b1, b_pri[xb], b_colour[xb] | {5'd0, pen}};
					if (x == 9'd287) begin
						xs_run <= 1'b0; b_full[xb] <= 1'b0; xk <= xk + 1'd1;
					end
					x <= x + 1'd1;
				end
			end
		end
	end
endmodule
