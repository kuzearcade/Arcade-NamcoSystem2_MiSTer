// Appendix F's M10K probe (docs/PLAN.md, M0): the standard board's on-chip
// arrays at their real shapes and port use, fitted alone, so the fitter's
// per-entity report gives each array's M10K count. sys/ and the emu-level
// blocks outside the core are measured from a sibling's fitted build.
//   sp   one port (a CPU's own RAM)
//   tdp  two read/write ports (a CPU and the video, or two CPUs, or a CPU and
//        the ioctl / savestate path)
//   sdp  one write port and one read port (tables filled at load, caches)
// Every array is kept alive by an LFSR driving its ports and an XOR tree of
// its outputs to one pin.
module m10k_probe (
	input  clk,
	input  seed,
	output q
);
	reg [63:0] l = 64'h1;
	always @(posedge clk) l <= {l[62:0], l[63] ^ l[62] ^ l[60] ^ l[59] ^ seed};

	wire [63:0] r [0:15];
	// work RAMs, 64 KB each (Q2), byte lanes
	sp  #(15, 16) master_ram (clk, l[14:0],  l[63:48], l[0], l[2:1], r[0]);
	sp  #(15, 16) slave_ram  (clk, l[15:1],  l[62:47], l[1], l[3:2], r[1]);
	// video RAMs: the CPU and the video
	tdp #(15, 16) tmap_ram   (clk, l[16:2],  l[61:46], l[2], l[4:3], l[31:17], l[40:25], l[41], r[2]);
	tdp #(16, 16) roz_ram    (clk, l[17:2],  l[60:45], l[3], l[5:4], l[33:18], l[42:27], l[43], r[3]);
	tdp #(13, 16) spr_ram    (clk, l[18:6],  l[59:44], l[4], l[6:5], l[34:22], l[44:29], l[45], r[4]);
	tdp #(13, 8)  pal_r      (clk, l[19:7],  l[58:51], l[5], 2'b01, l[35:23], l[46:39], l[47], r[5]);
	tdp #(13, 8)  pal_g      (clk, l[20:8],  l[57:50], l[6], 2'b01, l[36:24], l[47:40], l[48], r[6]);
	tdp #(13, 8)  pal_b      (clk, l[21:9],  l[56:49], l[7], 2'b01, l[37:25], l[48:41], l[49], r[7]);
	// DPRAM (68000s / 6809 / MCU, arbitrated to two ports), sound RAM,
	// EEPROM (CPU + the NVRAM ioctl)
	tdp #(11, 8)  dpram2k    (clk, l[22:12], l[55:48], l[8], 2'b01, l[38:28], l[49:42], l[50], r[8]);
	sp  #(13, 8)  snd_ram    (clk, l[23:11], l[54:47], l[9], 2'b01, r[9]);
	tdp #(13, 8)  eeprom     (clk, l[24:12], l[53:46], l[10], 2'b01, l[40:28], l[50:43], l[51], r[10]);
	// D3 (NS2-3): the tile class table 64K x 2, the tile-row and mask caches
	// (256 x 64 data each, and their tags)
	sdp #(16, 2)  tile_class (clk, l[25:10], l[52:51], l[11], l[41:26], r[11]);
	sdp #(8, 64)  tile_cache (clk, l[26:19], l,        l[12], l[42:35], r[12]);
	sdp #(8, 64)  mask_cache (clk, l[27:20], ~l,       l[13], l[43:36], r[13]);
	sdp #(9, 20)  cache_tags (clk, l[28:20], l[63:44], l[14], l[44:36], r[14]);
	// the sprite line buffers, double (2 x 512 x 16)
	sdp #(10, 16) spr_line   (clk, l[29:20], l[47:32], l[15], l[45:36], r[15]);

	wire [63:0] x = r[0] ^ r[1] ^ r[2] ^ r[3] ^ r[4] ^ r[5] ^ r[6] ^ r[7] ^
	                r[8] ^ r[9] ^ r[10] ^ r[11] ^ r[12] ^ r[13] ^ r[14] ^ r[15];
	assign q = ^x;
endmodule

module sp #(parameter AW = 10, DW = 8) (
	input clk, input [AW-1:0] a, input [DW-1:0] d, input we, input [1:0] be, output [63:0] rq
);
	generate
		if (DW > 8) begin : g16
			reg [1:0][7:0] m [0:(1 << AW) - 1];
			reg [15:0] q;
			always @(posedge clk) begin
				if (we && be[0]) m[a][0] <= d[7:0];
				if (we && be[1]) m[a][1] <= d[15:8];
				q <= m[a];
			end
			assign rq = {48'd0, q};
		end else begin : g8
			reg [7:0] m [0:(1 << AW) - 1];
			reg [7:0] q;
			always @(posedge clk) begin
				if (we) m[a] <= d;
				q <= m[a];
			end
			assign rq = {56'd0, q};
		end
	endgenerate
endmodule

// a 16-bit array is two 8-bit lanes (Quartus infers true dual port only
// without byte enables); DW 8 uses one lane
module tdp #(parameter AW = 10, DW = 8) (
	input clk,
	input [AW-1:0] a, input [DW-1:0] d, input we, input [1:0] be,
	input [AW-1:0] b, input [DW-1:0] e, input web,
	output [63:0] rq
);
	wire [7:0] q0, q1;
	tdp8 #(AW) lo (clk, a, d[7:0], we & be[0], b, e[7:0], web, q0);
	generate
		if (DW > 8) begin : g_hi
			tdp8 #(AW) hi (clk, a, d[DW-1:8], we & be[1], b, e[DW-1:8], web, q1);
		end else begin : g_nohi
			assign q1 = 8'd0;
		end
	endgenerate
	assign rq = {48'd0, q1, q0};
endmodule

module tdp8 #(parameter AW = 10) (
	input clk,
	input [AW-1:0] a, input [7:0] d, input we,
	input [AW-1:0] b, input [7:0] e, input web,
	output [7:0] q
);
	reg [7:0] m [0:(1 << AW) - 1];
	reg [7:0] qa, qb;
	// Intel's true dual port template: a port reads its own new data
	always @(posedge clk) begin
		if (we) begin m[a] <= d; qa <= d; end
		else qa <= m[a];
	end
	always @(posedge clk) begin
		if (web) begin m[b] <= e; qb <= e; end
		else qb <= m[b];
	end
	assign q = qa ^ qb;
endmodule

module sdp #(parameter AW = 10, DW = 8) (
	input clk, input [AW-1:0] wa, input [DW-1:0] d, input we, input [AW-1:0] ra, output [63:0] rq
);
	reg [DW-1:0] m [0:(1 << AW) - 1];
	reg [DW-1:0] q;
	always @(posedge clk) begin
		if (we) m[wa] <= d;
		q <= m[ra];
	end
	assign rq = {{(64 - DW){1'b0}}, q};
endmodule
