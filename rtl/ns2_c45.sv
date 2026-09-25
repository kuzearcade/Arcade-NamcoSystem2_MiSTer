// C45 road (namco_c45road.cpp draw; tools/ns2_model.py road_line is the
// specification): renders one line of the road into the ROZ line buffer
// (a board has one or the other), with the line's priority.
//
// Road RAM (64K words): 0x0000 the 64 x 512 map of 16 x 16 tiles (tile
// 10 bits, colour 6), 0x8000 the 2 bpp tiles (1000 of them, 32 words each,
// a row = two big-endian words: plane 0 in the high byte, plane 1 in the low,
// leftmost pixel in bit 7), 0xfd00 the line RAM:
//   [y + 15]          priority (15-12), screen x (11-0, signed)
//   [0x100 + y + 15]  source line, + [0x1ff] the y scroll
//   [0x200 + y + 15]  zoom (9-0): the source advances (1024 << 16) / zoom a pixel
// The line draws floor((704 << 16) / step) pixels from screen x - 72; every
// pixel is drawn (no transparent pen on System 2), coloured
// 0xf00 | clut[(colour * 4 + pixel) & 0xff].
module ns2_c45 (
	input             clk,
	input             reset,
	input             start,
	input      [7:0]  y,
	output reg        busy,
	// road RAM, video port: data one clock after the address
	output reg [15:0] rd_addr,
	input      [15:0] rd_data,
	// the 256-byte CLUT: data one clock after the address
	output reg [7:0]  clut_addr,
	input      [7:0]  clut_data,
	// the line's priority (with a drawn line)
	output reg        attr_we,
	output reg [3:0]  attr_pri,
	// ROZ/road line buffer: {valid, pen}
	output reg        lb_we,
	output reg [8:0]  lb_x,
	output reg [8:0]  lb_d
);
	localparam S_IDLE = 0, S_RD = 1, S_DIV = 2, S_START = 3, S_CROP = 4, S_COL = 5, S_COLW = 6, S_PIX = 7;
	reg [2:0]  st;
	reg [2:0]  rn;            // line RAM reads issued
	reg [15:0] screenx, srcy;
	reg [9:0]  zoom;
	reg [26:0] q, rem;        // the step, by restoring division
	reg [4:0]  dn;
	reg [26:0] step;
	reg signed [13:0] sx;
	reg [8:0]  x;
	reg [27:0] srcx;
	reg [12:0] sy;
	reg [5:0]  col;
	reg [6:0]  col_l;         // the column held in w0/w1 (bit 6: none)
	reg [1:0]  cr;
	reg [15:0] w0, w1;
	reg [5:0]  colour;
	// the pixel pipeline: CLUT address, CLUT data, write
	reg        p1_v, p2_v;
	reg [8:0]  p1_x, p2_x;

	wire [9:0]  spx  = srcx[25:16];
	wire [3:0]  px   = spx[3:0];
	wire [15:0] w    = px[3] ? w1 : w0;
	wire [2:0]  b    = px[2:0];
	wire [1:0]  pix  = {w[15 - b], w[7 - b]};
	wire [28:0] nsrc = {1'b0, srcx} + {2'b0, step};      // 29 bits: a saturated crop must not wrap
	wire        more = nsrc <= (29'd704 << 16);
	wire [9:0]  tnum = rd_data[9:0] >= 10'd1000 ? rd_data[9:0] - 10'd1000 : rd_data[9:0];
	wire [40:0] crop = $unsigned(-sx) * step;

	always @(posedge clk) begin
		lb_we <= 1'b0; attr_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; p1_v <= 1'b0; p2_v <= 1'b0;
		end else begin
			p1_v <= 1'b0;
			p2_v <= p1_v; p2_x <= p1_x;
			if (p2_v) begin lb_we <= 1'b1; lb_x <= p2_x; lb_d <= {1'b1, clut_data}; end
			case (st)
				S_IDLE: if (start) begin busy <= 1'b1; rn <= 0; st <= S_RD; end
				S_RD: begin
					// four line RAM words back to back; each is in two clocks later
					case (rn)
						3'd0: rd_addr <= 16'hfd00 + y + 16'd15;
						3'd1: rd_addr <= 16'hfd00 + 16'h200 + y + 16'd15;
						3'd2: rd_addr <= 16'hfd00 + 16'h100 + y + 16'd15;
						3'd3: rd_addr <= 16'hfd00 + 16'h1ff;
						default: ;
					endcase
					if (rn == 3'd2) screenx <= rd_data;
					if (rn == 3'd3) zoom <= rd_data[9:0];
					if (rn == 3'd4) srcy <= rd_data;
					if (rn == 3'd5) begin
						sy <= srcy[12:0] + rd_data[12:0];
						if (zoom == 0) begin busy <= 1'b0; st <= S_IDLE; end
						else begin q <= 0; rem <= 0; dn <= 5'd26; st <= S_DIV; end
					end
					rn <= rn + 1'd1;
				end
				S_DIV: begin
					// (1 << 26) / zoom, a quotient bit a clock, MSB first
					if ({rem[25:0], dn == 5'd26} >= {17'd0, zoom}) begin
						rem <= {rem[25:0], dn == 5'd26} - {17'd0, zoom};
						q <= {q[25:0], 1'b1};
					end else begin
						rem <= {rem[25:0], dn == 5'd26};
						q <= {q[25:0], 1'b0};
					end
					if (dn == 0) st <= S_START;
					dn <= dn - 1'd1;
				end
				S_START: begin
					step <= q;
					sx <= $signed({{2{screenx[11]}}, screenx[11:0]}) - 14'sd72;
					attr_we <= 1'b1; attr_pri <= screenx[15:12];
					st <= S_CROP;
				end
				S_CROP: begin
					// crop left: start at screen x 0 with the source advanced
					if (sx > 14'sd287) begin busy <= 1'b0; st <= S_IDLE; end
					else begin
						x <= sx < 0 ? 9'd0 : sx[8:0];
						srcx <= sx >= 0 ? 28'd0 : (crop[40:27] != 0 ? 28'hfffffff : {1'b0, crop[26:0]});
						col_l <= 7'h40;
						st <= S_PIX;
					end
				end
				S_COL: begin
					// the map word (in at cr 2), then the row's two tile words
					if (cr == 2'd0) rd_addr <= {1'b0, sy[12:4], col};
					if (cr == 2'd2) begin
						colour  <= rd_data[15:10];
						rd_addr <= 16'h8000 + {tnum, 5'd0} + {11'd0, sy[3:0], 1'b0};
					end
					if (cr == 2'd3) begin rd_addr <= rd_addr + 1'd1; st <= S_COLW; end
					cr <= cr + 1'd1;
				end
				S_COLW: begin
					if (cr == 2'd0) begin w0 <= rd_data; cr <= 2'd1; end
					else begin w1 <= rd_data; col_l <= {1'b0, col}; st <= S_PIX; end
				end
				S_PIX: begin
					if (!more || x > 9'd287) begin
						if (!p1_v && !p2_v) begin busy <= 1'b0; st <= S_IDLE; end
					end else if ({1'b0, spx[9:4]} != col_l) begin col <= spx[9:4]; cr <= 0; st <= S_COL; end
					else begin
						clut_addr <= {colour, pix};
						p1_v <= 1'b1; p1_x <= x;
						x <= x + 1'd1;
						srcx <= srcx + {1'b0, step};
					end
				end
				default: st <= S_IDLE;
			endcase
		end
	end
endmodule
