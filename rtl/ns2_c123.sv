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

	localparam S_IDLE = 0, S_SEL = 1, S_SETUP = 2, S_ADDR = 3, S_CODE = 4, S_REQ = 5, S_WAIT = 6, S_PIX = 7;
	reg [2:0]  st;
	reg [2:0]  p;             // the priority being drawn
	reg [2:0]  i;             // the plane
	reg        flip, fixed;
	reg [9:0]  u0;            // scroll x + dx
	reg [8:0]  ty;
	reg [5:0]  k, nslots, t_rx, m_rx;
	reg [8:0]  x;
	reg [12:0] colour;
	reg [63:0] pix  [0:36];
	reg [7:0]  mask [0:36];
	reg        t_done, m_done;
	reg [7:0]  yl;

	// the plane's control words, scroll and row
	wire [15:0] lctl  = cw(16 + i);      // priority, bit 3 = off
	wire [15:0] lcol  = cw(24 + i);      // colour bank
	wire [15:0] ctl1  = cw(1);           // bit 15 = flip
	wire [8:0] sx = cw(4 * i + 1) & 9'h1ff;
	wire [8:0] sy = cw(4 * i + 3) & 9'h1ff;
	wire [5:0] dx = i == 0 ? 6'd48 : i == 1 ? 6'd46 : i == 2 ? 6'd45 : 6'd44;
	wire [8:0] ty_s = yl + sy + 9'd24;
	wire [6:0] ku = u0[9:3] + k;
	wire [5:0] mc = fixed ? (flip ? 6'd35 - k : k) : (flip ? 6'd63 - ku[5:0] : ku[5:0]);
	wire [14:0] map_addr = fixed ? (i == 4 ? 15'h4008 : 15'h4408) + ty[7:3] * 36 + mc
	                             : {i[1:0], ty[8:3], mc};
	// the pixel stage
	wire [9:0] xu  = x + u0[2:0];
	wire [5:0] s   = xu[8:3];
	wire [2:0] col = flip ? 3'd7 - xu[2:0] : xu[2:0];
	wire [7:0] pen = pix[s][8 * col +: 8];
	wire       op  = mask[s][3'd7 - col];

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; t_req <= 1'b0; m_req <= 1'b0;
		end else case (st)
			S_IDLE: if (start) begin
				yl <= y; p <= 0; i <= 0; busy <= 1'b1; st <= S_SEL;
			end
			S_SEL: begin
				// planes in MAME's order: priority, then plane number
				if (lctl[2:0] == p && !lctl[3]) st <= S_SETUP;
				else if (i == 5) begin
					i <= 0;
					if (p == 7) begin busy <= 1'b0; st <= S_IDLE; end
					else p <= p + 1'd1;
				end else i <= i + 1'd1;
			end
			S_SETUP: begin
				flip   <= ctl1[15];
				fixed  <= i >= 4;
				colour <= 13'h1000 | {2'b00, lcol[2:0], 8'h00};
				k <= 0; t_rx <= 0; m_rx <= 0;
				if (i < 4) begin
					u0 <= sx + dx;
					ty <= ctl1[15] ? 9'd511 - ty_s : ty_s;
					nslots <= 6'd37;
				end else begin
					u0 <= 0;
					ty <= ctl1[15] ? 9'd223 - yl : {1'b0, yl};
					nslots <= 6'd36;
				end
				st <= S_ADDR;
			end
			S_ADDR: begin vr_addr <= map_addr; st <= S_CODE; end
			S_CODE: st <= S_REQ;          // the RAM's latency
			S_REQ: begin
				t_req <= 1'b1; t_addr <= {tile_cb(vr_data), ty[2:0]};
				m_req <= 1'b1; m_addr <= {vr_data, ty[2:0]};
				t_done <= 1'b0; m_done <= 1'b0;
				st <= S_WAIT;
			end
			S_WAIT: begin
				if (t_ack) begin t_req <= 1'b0; t_done <= 1'b1; end
				if (m_ack) begin m_req <= 1'b0; m_done <= 1'b1; end
				if ((t_done || t_ack) && (m_done || m_ack)) begin
					if (k + 1'd1 == nslots) st <= S_PIX;
					else begin k <= k + 1'd1; st <= S_ADDR; end
				end
				x <= 0;
			end
			S_PIX: if (t_rx == nslots && m_rx == nslots) begin
				// all slots in: one pixel a clock
				lb_we <= op; lb_x <= x; lb_d <= {1'b1, p, colour | {5'd0, pen}};
				if (x == 9'd287) begin
					st <= S_SEL;
					if (i == 5) begin
						i <= 0;
						if (p == 7) begin busy <= 1'b0; st <= S_IDLE; end
						else p <= p + 1'd1;
					end else i <= i + 1'd1;
				end
				x <= x + 1'd1;
			end
		endcase
		// responses, in order
		if (!reset && t_valid) begin pix[t_rx] <= t_data; t_rx <= t_rx + 1'd1; end
		if (!reset && m_valid) begin mask[m_rx] <= m_data; m_rx <= m_rx + 1'd1; end
		if (st == S_SETUP) begin t_rx <= 0; m_rx <= 0; end
	end
endmodule
