// The core's SDRAM (M3, docs/PLAN.md 2.3 and Appendix D): the download,
// the banks' layout and their clients. 16-bit word addresses per bank:
//   bank 0: ROZ (copy A) 000000, data ROM 200000, master 300000, slave 320000,
//           audio 340000, MCU EPROM 360000, MCU internal ROM 364000
//   bank 1: ROZ (copy B) 000000, C140 voices 200000
//   bank 2: tiles 000000, tile mask 200000, C169 mask 240000
//   bank 3: sprites 000000 (Metal Hawk: the transposed copy at 200000)
// The download is the .mra image (tools/ns2_romdata.py LAYOUT), 16-bit
// words, the even byte low. It applies the board wiring MAME applies after
// loading (tools/ns2_romdata.py WIRING): Metal Hawk's sprite reorder (a byte
// lands in 0, 1 or 2 places) and its transposed copy for the rot90 sprites,
// and Lucky & Wild's bit-reversed C169 mask. It also fills the tile class
// table from the tile mask (2 bits a tile: 0 transparent, 1 opaque, 2 mixed)
// and loads the C45 CLUT and the default NVRAM.
// The ROZ stream alternates between its two copies (banks 0 and 1) and its
// bursts come back in request order.
module ns2_mem (
	input             clk,
	input             rst,
	input      [2:0]  board,          // ns2_video's board code
	input             mh_wiring,      // Metal Hawk (init_metlhawk)
	input             lw_wiring,      // Lucky & Wild (init_luckywld)
	// the download
	input             dl,             // downloading index 0
	input             dl_wr,
	input      [24:0] dl_addr,        // byte address in the image (even)
	input      [15:0] dl_data,        // {byte addr + 1, byte addr}
	output            dl_wait,
	output reg        clut_we,
	output reg [7:0]  clut_addr,
	output reg [7:0]  clut_data,
	output reg        nv_we,
	output reg [12:0] nv_addr,
	output reg [7:0]  nv_data,
	output reg        class_we,
	output reg [15:0] class_addr,
	output reg [1:0]  class_data,
	// the video's streams (bursts: 64-bit, byte n at [8n +: 8])
	input             tile_req,  input [18:0] tile_addr,  output tile_ack,  output tile_valid,  output [63:0] tile_data,
	input             tmask_req, input [15:0] tmask_addr, output tmask_ack, output tmask_valid, output [63:0] tmask_data,   // a tile code's 8 mask bytes (ns2_tile_filter)
	input             roz_req,   input [18:0] roz_addr,   output roz_ack,   output roz_valid,   output [63:0] roz_data,
	input             c169_req,  input [20:0] c169_addr,  output c169_ack,  output c169_valid,  output [63:0] c169_data,
	input             c169m_req, input [18:0] c169m_addr, output c169m_ack, output c169m_valid, output [7:0]  c169m_data,
	input             spr_req,   input [19:0] spr_addr,   output spr_ack,   output spr_valid,   output [63:0] spr_data,
	// the CPUs' caches and the C140: the same streams, word addresses of a burst
	input             mprog_req, input [16:0] mprog_addr, output mprog_ack, output mprog_valid,
	input             sprog_req, input [16:0] sprog_addr, output sprog_ack, output sprog_valid,
	input             drom_req,  input [19:0] drom_addr,  output drom_ack,  output drom_valid,
	input             aud_req,   input [16:0] aud_addr,   output aud_ack,   output aud_valid,
	input             mcu_req,   input [14:0] mcu_addr,   output mcu_ack,   output mcu_valid,   // 32K words: EPROM, then the internal ROM
	input             c140_req,  input [19:0] c140_addr,  output c140_ack,  output c140_valid,
	output     [63:0] bank0_data,     // the bank 0 and 1 clients' bursts
	output     [63:0] bank1_data,
	// ns2_sdram
	output     [21:0] sd_addr0, sd_addr1, sd_addr2, sd_addr3,
	output     [3:0]  sd_push,
	input      [3:0]  sd_full,
	input      [3:0]  sd_valid_t,
	input      [63:0] sd_data0, sd_data1, sd_data2, sd_data3,
	output reg [21:0] prog_addr,
	output reg [1:0]  prog_ba,
	output reg [15:0] prog_din,
	output reg [1:0]  prog_dsn,
	output reg        prog_req_t,
	input             prog_ack_t
);
	// ======================================================== the download
	// the writes one image word makes: up to 8 (Metal Hawk's sprites: two
	// bytes, each to two places and their transposed copies)
	reg [21:0] w_addr [0:7];
	reg [1:0]  w_ba   [0:7];
	reg [15:0] w_din  [0:7];
	reg [1:0]  w_dsn  [0:7];
	reg [3:0]  w_n, w_i;
	reg        busy;
	reg        wait_ack;
	assign dl_wait = busy || hi_clut || hi_nv;

	// Metal Hawk's reorder, per 4x4 block of a 32x32 tile: where a source
	// byte (row r, column c in the block) goes; MAME's loop carries one byte
	// into two places and drops another (tools/ns2_romdata.py _metlhawk_sprite)
	function [5:0] mh_dst(input [1:0] r, input [1:0] c, input second);
		// {valid, row, col, unused}: the first or second destination
		reg [4:0] d1, d2;
		begin
			d1 = 5'h00; d2 = 5'h00;
			case ({r, c})
				4'h0, 4'h1, 4'h2, 4'h3: d1 = {1'b1, r, c};
				4'h4: d1 = {1'b1, 2'd3, 2'd1};  4'h5: d1 = {1'b1, 2'd3, 2'd2};
				4'h6: d1 = {1'b1, 2'd3, 2'd3};  4'h7: d1 = {1'b1, 2'd3, 2'd0};
				4'h8: d1 = {1'b1, 2'd2, 2'd2};
				4'h9: begin d1 = {1'b1, 2'd1, 2'd3}; d2 = {1'b1, 2'd2, 2'd3}; end
				4'ha: d1 = {1'b1, 2'd2, 2'd0};  4'hb: d1 = {1'b1, 2'd2, 2'd1};
				4'hc: d1 = 5'h00;
				4'hd: d1 = {1'b1, 2'd1, 2'd0};  4'he: d1 = {1'b1, 2'd1, 2'd1};
				default: d1 = {1'b1, 2'd1, 2'd2};
			endcase
			mh_dst = {second ? d2 : d1, 1'b0};
		end
	endfunction

	function [7:0] rev8(input [7:0] b);
		rev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
	endfunction

	// the tile class: the mask's 8 bytes of a tile
	reg [7:0] cls_and, cls_or;
	// the CLUT's and the NVRAM's second byte, the clock after
	reg       hi_clut, hi_nv;
	reg [7:0] hi_data;
	reg [12:0] hi_addr;

	integer i;
	reg [3:0]  n;
	reg [24:0] a;
	always @(posedge clk) begin
		clut_we <= 1'b0; nv_we <= 1'b0; class_we <= 1'b0;
		hi_clut <= 1'b0; hi_nv <= 1'b0;
		if (hi_clut) begin clut_we <= 1'b1; clut_addr <= hi_addr[7:0]; clut_data <= hi_data; end
		if (hi_nv)   begin nv_we <= 1'b1; nv_addr <= hi_addr; nv_data <= hi_data; end
		if (rst) begin busy <= 1'b0; wait_ack <= 1'b0; w_n <= 0; w_i <= 0; end
		else if (!busy && !hi_clut && !hi_nv) begin
			if (dl && dl_wr) begin
				a = dl_addr;
				n = 0;
				// the plain regions: one write to one bank (offsets in words)
				if (a < 25'h00C0000) begin
					w_ba[0] = 0; n = 1;
					w_addr[0] = a < 25'h0040000 ? 22'h300000 + (a >> 1) : a < 25'h0080000 ? 22'h320000 + ((a - 25'h0040000) >> 1) :
					            22'h340000 + ((a - 25'h0080000) >> 1);                          // master, slave, audio
				end
				else if (a < 25'h00D0000) begin w_ba[0] = 0; w_addr[0] = 22'h360000 + ((a - 25'h00C0000) >> 1); n = 1; end   // MCU EPROM, internal ROM
				else if (a < 25'h00D0100) begin                                                  // the C45 CLUT: two bytes
					clut_we <= 1'b1; clut_addr <= a[7:0]; clut_data <= dl_data[7:0];
					hi_clut <= 1'b1; hi_data <= dl_data[15:8]; hi_addr <= a[12:0] + 1'd1;
				end
				else if (a >= 25'h00D1000 && a < 25'h00D3000) begin                              // the default NVRAM: two bytes
					nv_we <= 1'b1; nv_addr <= 13'(a - 25'h00D1000); nv_data <= dl_data[7:0];
					hi_nv <= 1'b1; hi_data <= dl_data[15:8]; hi_addr <= 13'(a - 25'h00D1000) + 1'd1;
				end
				else if (a >= 25'h0100000 && a < 25'h0300000) begin w_ba[0] = 0; w_addr[0] = 22'h200000 + ((a - 25'h0100000) >> 1); n = 1; end   // data ROM
				else if (a >= 25'h0300000 && a < 25'h0500000) begin w_ba[0] = 1; w_addr[0] = 22'h200000 + ((a - 25'h0300000) >> 1); n = 1; end   // C140
				else if (a >= 25'h0500000 && a < 25'h0580000) begin w_ba[0] = 2; w_addr[0] = 22'h200000 + ((a - 25'h0500000) >> 1); n = 1; end   // tile mask
				else if (a >= 25'h0580000 && a < 25'h0600000) begin w_ba[0] = 2; w_addr[0] = 22'h240000 + ((a - 25'h0580000) >> 1); n = 1; end   // C169 mask
				else if (a >= 25'h0600000 && a < 25'h0A00000) begin w_ba[0] = 2; w_addr[0] = (a - 25'h0600000) >> 1; n = 1; end                 // tiles
				else if (a >= 25'h0A00000 && a < 25'h0E00000) begin w_ba[0] = 3; w_addr[0] = (a - 25'h0A00000) >> 1; n = 1; end                 // sprites
				else if (a >= 25'h0E00000 && a < 25'h1200000) begin                                                                             // ROZ, twice
					w_ba[0] = 0; w_addr[0] = (a - 25'h0E00000) >> 1;
					w_ba[1] = 1; w_addr[1] = (a - 25'h0E00000) >> 1; n = 2;
				end
				for (i = 0; i < 2; i = i + 1) begin w_din[i] = dl_data; w_dsn[i] = 2'b00; end
				// Lucky & Wild's C169 mask: each byte bit-reversed
				if (lw_wiring && a >= 25'h0580000 && a < 25'h0600000) w_din[0] = {rev8(dl_data[15:8]), rev8(dl_data[7:0])};
				// Metal Hawk's sprites: byte writes, the reorder and the transposed copy
				if (mh_wiring && a >= 25'h0A00000 && a < 25'h0E00000) begin : mh
					reg [21:0] boff;          // the byte offset in the region
					reg [5:0]  d;
					reg [9:0]  loc, tloc;
					integer    bb, s;
					n = 0;
					for (bb = 0; bb < 2; bb = bb + 1)
						for (s = 0; s < 2; s = s + 1) begin
							boff = 22'(a - 25'h0A00000) + bb;
							d = mh_dst(boff[6:5], boff[1:0], s[0]);
							if (d[5]) begin
								// the destination in the tile: the block's origin plus (row, col)
								loc  = {boff[9:7], d[4:3], boff[4:2], d[2:1]};
								// transposed: row and column swap
								tloc = {loc[4:0], loc[9:5]};
								w_ba[n] = 3; w_addr[n] = {boff[21:10], loc[9:1]};
								w_din[n] = {2{bb ? dl_data[15:8] : dl_data[7:0]}}; w_dsn[n] = loc[0] ? 2'b01 : 2'b10; n = n + 1;
								w_ba[n] = 3; w_addr[n] = 22'h200000 + {boff[21:10], tloc[9:1]};
								w_din[n] = {2{bb ? dl_data[15:8] : dl_data[7:0]}}; w_dsn[n] = tloc[0] ? 2'b01 : 2'b10; n = n + 1;
							end
						end
				end
				// the tile class: four words a tile
				if (a >= 25'h0500000 && a < 25'h0580000) begin
					if (a[2:1] == 2'd0) begin cls_and <= dl_data[15:8] & dl_data[7:0]; cls_or <= dl_data[15:8] | dl_data[7:0]; end
					else begin cls_and <= cls_and & dl_data[15:8] & dl_data[7:0]; cls_or <= cls_or | dl_data[15:8] | dl_data[7:0]; end
					if (a[2:1] == 2'd3) begin
						class_we <= 1'b1; class_addr <= a[18:3];
						class_data <= (cls_or | dl_data[15:8] | dl_data[7:0]) == 8'h00 ? 2'd0 :
						              (cls_and & dl_data[15:8] & dl_data[7:0]) == 8'hff ? 2'd1 : 2'd2;
					end
				end
				w_n <= n; w_i <= 0;
				busy <= n != 0;
			end
		end else begin
			// the writes, one at a time through the programming port
			if (!wait_ack) begin
				prog_addr <= w_addr[w_i]; prog_ba <= w_ba[w_i]; prog_din <= w_din[w_i]; prog_dsn <= w_dsn[w_i];
				prog_req_t <= ~prog_req_t; wait_ack <= 1'b1;
			end else if (prog_ack_t == prog_req_t) begin
				wait_ack <= 1'b0;
				if (w_i + 1'd1 == w_n) busy <= 1'b0;
				w_i <= w_i + 1'd1;
			end
		end
	end

	// ======================================================== the banks
	// the ROZ stream: the video's (standard) or the C169's (Metal Hawk,
	// Lucky & Wild), alternating between banks 0 and 1
	wire        c169b = board == 3'd2 || board == 3'd5;
	wire        rz_req  = c169b ? c169_req : roz_req;
	wire [21:0] rz_word = c169b ? {c169_addr[18:0], 2'b00} : {roz_addr, 2'b00};   // bursts of four words
	reg         rz_bank;                      // the bank of the next ROZ request
	wire [1:0]  rz_ack_b, rz_val_b;

	// bank 0: ROZ A, master, slave, data ROM, audio, MCU
	wire [5:0]  a0_ack, a0_val;
	ns2_bank_arb #(.N(6)) u_b0 (.clk(clk), .rst(rst),
		.req({mcu_req, aud_req, drom_req, sprog_req, mprog_req, rz_req && !rz_bank}),
		.addr({22'h360000 + {5'd0, mcu_addr, 2'b00}, 22'h340000 + {3'd0, aud_addr, 2'b00}, 22'h200000 + {drom_addr, 2'b00},
		       22'h320000 + {3'd0, sprog_addr, 2'b00}, 22'h300000 + {3'd0, mprog_addr, 2'b00}, rz_word}),
		.ack(a0_ack), .valid(a0_val), .data(bank0_data),
		.push(sd_push[0]), .paddr(sd_addr0), .full(sd_full[0]), .vtog(sd_valid_t[0]), .vdata(sd_data0));
	assign {mcu_ack, aud_ack, drom_ack, sprog_ack, mprog_ack} = a0_ack[5:1];
	assign {mcu_valid, aud_valid, drom_valid, sprog_valid, mprog_valid} = a0_val[5:1];

	// bank 1: ROZ B, the C140
	wire [1:0]  a1_ack, a1_val;
	ns2_bank_arb #(.N(2)) u_b1 (.clk(clk), .rst(rst),
		.req({c140_req, rz_req && rz_bank}),
		.addr({22'h200000 + {c140_addr, 2'b00}, rz_word}),
		.ack(a1_ack), .valid(a1_val), .data(bank1_data),
		.push(sd_push[1]), .paddr(sd_addr1), .full(sd_full[1]), .vtog(sd_valid_t[1]), .vdata(sd_data1));
	assign c140_ack = a1_ack[1];
	assign c140_valid = a1_val[1];

	// the ROZ stream's acks and its bursts, back in request order: each bank
	// returns its own in order, so a small FIFO per bank and the order of
	// the requests (alternating) put them together
	assign rz_ack_b = {a1_ack[0], a0_ack[0]};
	assign rz_val_b = {a1_val[0], a0_val[0]};
	always @(posedge clk) if (rst) rz_bank <= 1'b0; else if (|rz_ack_b) rz_bank <= ~rz_bank;
	reg [63:0] rq [0:1][0:3];
	reg [2:0]  rq_w [0:1], rq_r [0:1];
	reg        rz_next;                       // the bank of the next burst out
	reg        rz_out_v;
	reg [63:0] rz_out;
	integer    q;
	always @(posedge clk) begin
		rz_out_v <= 1'b0;
		if (rst) begin rq_w[0] <= 0; rq_w[1] <= 0; rq_r[0] <= 0; rq_r[1] <= 0; rz_next <= 1'b0; end
		else begin
			for (q = 0; q < 2; q = q + 1)
				if (rz_val_b[q]) begin rq[q][rq_w[q][1:0]] <= q ? bank1_data : bank0_data; rq_w[q] <= rq_w[q] + 1'd1; end
			if (rq_w[rz_next] != rq_r[rz_next]) begin
				rz_out_v <= 1'b1; rz_out <= rq[rz_next][rq_r[rz_next][1:0]];
				rq_r[rz_next] <= rq_r[rz_next] + 1'd1;
				rz_next <= ~rz_next;
			end
		end
	end
	assign roz_ack   = !c169b && |rz_ack_b;
	assign c169_ack  = c169b && |rz_ack_b;
	assign roz_valid = !c169b && rz_out_v;
	assign c169_valid = c169b && rz_out_v;
	assign roz_data  = rz_out;
	assign c169_data = rz_out;

	// bank 2: tiles, the tile mask, the C169 mask (byte streams: the byte of the burst)
	wire [2:0]  a2_ack, a2_val;
	wire [63:0] b2_data;
	ns2_bank_arb #(.N(3)) u_b2 (.clk(clk), .rst(rst),
		.req({c169m_req, tmask_req, tile_req}),
		.addr({22'h240000 + {3'd0, c169m_addr[18:3], 2'b00}, 22'h200000 + {4'd0, tmask_addr, 2'b00}, {1'b0, tile_addr, 2'b00}}),
		.ack(a2_ack), .valid(a2_val), .data(b2_data),
		.push(sd_push[2]), .paddr(sd_addr2), .full(sd_full[2]), .vtog(sd_valid_t[2]), .vdata(sd_data2));
	assign {c169m_ack, tmask_ack, tile_ack} = a2_ack;
	assign {c169m_valid, tmask_valid, tile_valid} = a2_val;
	assign tile_data = b2_data;
	// the C169 mask: a byte stream (the byte of the burst, in request order)
	reg [2:0]  cm_q [0:7];
	reg [3:0]  cm_w, cm_r;
	always @(posedge clk) begin
		if (rst) begin cm_w <= 0; cm_r <= 0; end
		else begin
			if (a2_ack[2]) begin cm_q[cm_w[2:0]] <= c169m_addr[2:0]; cm_w <= cm_w + 1'd1; end
			if (a2_val[2]) cm_r <= cm_r + 1'd1;
		end
	end
	assign tmask_data = b2_data;
	assign c169m_data = b2_data[8 * cm_q[cm_r[2:0]] +: 8];

	// bank 3: sprites (Metal Hawk's rot90: bit 19, the transposed copy)
	wire [0:0]  a3_ack, a3_val;
	ns2_bank_arb #(.N(1)) u_b3 (.clk(clk), .rst(rst),
		.req(spr_req), .addr({spr_addr[19] ? 1'b1 : 1'b0, spr_addr[18:0], 2'b00}),
		.ack(a3_ack), .valid(a3_val), .data(spr_data),
		.push(sd_push[3]), .paddr(sd_addr3), .full(sd_full[3]), .vtog(sd_valid_t[3]), .vdata(sd_data3));
	assign spr_ack = a3_ack[0];
	assign spr_valid = a3_val[0];
endmodule
