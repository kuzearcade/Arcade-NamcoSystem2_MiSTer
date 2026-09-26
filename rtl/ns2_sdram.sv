// The SDRAM (M3, docs/PLAN.md 2.3): jtframe_sdram64 at clk_sd (98.304 MHz,
// twice clk), four banks of 64-bit read bursts and the download's writes.
// The core runs at clk (49.152 MHz); the two clocks come from one PLL, in
// phase, so each crossing is a register-to-register path of one fast period:
// - requests: a four-entry FIFO per bank, written at clk (push with the
//   address when req_full is low), read at clk_sd: the controller always has
//   the next address when it accepts one;
// - data: the fast side gathers a burst's four words (bytes n at [8n +: 8]
//   of the 64 bits, the ROM's order) and toggles valid_t; the register holds
//   until the bank's next burst, at least two core clocks later.
// Bursts return in request order within a bank.
// The download writes 16-bit words through the controller's programming
// port: set prog_*, toggle prog_req_t, wait for prog_ack_t to follow.
// rfsh: the core asks for a round of refreshes (in hblank).
module ns2_sdram (
	input             clk,
	input             clk_sd,
	input             rst,
	output            init,           // high while the controller initialises (clk_sd domain)
	input             rfsh,
	// the banks: requests at clk, data back with a toggle
	input      [21:0] addr0, addr1, addr2, addr3,   // 16-bit words
	input      [3:0]  push,           // one clk strobe per request, the address with it
	output     [3:0]  req_full,
	output reg [3:0]  valid_t,
	output reg [63:0] data0, data1, data2, data3,
	// the download
	input      [21:0] prog_addr,
	input      [1:0]  prog_ba,
	input      [15:0] prog_din,
	input      [1:0]  prog_dsn,       // byte write mask, active low
	input             prog_en,        // the download is on
	input             prog_req_t,
	output reg        prog_ack_t,
	// the SDRAM
	inout      [15:0] SDRAM_DQ,
	output     [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output     [1:0]  SDRAM_BA,
	output            SDRAM_nWE,
	output            SDRAM_nCAS,
	output            SDRAM_nRAS,
	output            SDRAM_nCS,
	output            SDRAM_CKE
`ifdef VERILATOR
	, output   [15:0] sdram_din        // the model's input (Verilator: DQ is input only)
`endif
);
	// ------------------------------------------------ requests
	wire [3:0]  ack;
	wire [3:0]  rd;
	wire [21:0] qa [0:3];
	wire [21:0] ain [0:3];
	assign ain[0] = addr0; assign ain[1] = addr1; assign ain[2] = addr2; assign ain[3] = addr3;
	genvar gq;
	generate for (gq = 0; gq < 4; gq = gq + 1) begin : g_req
		reg [21:0] q [0:3];
		reg [2:0]  wp;                  // clk domain
		reg [2:0]  rp;                  // clk_sd domain
		always @(posedge clk)
			if (rst) wp <= 0;
			else if (push[gq] && !req_full[gq]) begin q[wp[1:0]] <= ain[gq]; wp <= wp + 1'd1; end
		assign req_full[gq] = (wp ^ rp) == 3'b100;
		// rd while the FIFO holds a request; the acceptance pops it, and the
		// controller's bank stays busy past it, so the next address is taken
		// only once the bank is ready
		assign rd[gq] = wp != rp;
		assign qa[gq] = q[rp[1:0]];
		always @(posedge clk_sd)
			if (rst) rp <= 0;
			else if (ack[gq] && rd[gq]) rp <= rp + 1'd1;
	end endgenerate

	// ------------------------------------------------ the download
	// the write: prog_wr until the controller accepts it (dropped then, as
	// rd), done at prog_rdy; the core holds the word until prog_ack_t turns
	reg  prog_seen, prog_wr, prog_busy;
	wire prog_ack, prog_rdy;
	always @(posedge clk_sd) begin
		if (rst) begin prog_seen <= 1'b0; prog_ack_t <= 1'b0; prog_wr <= 1'b0; prog_busy <= 1'b0; end
		else begin
			if (prog_req_t != prog_seen && !prog_busy) begin prog_wr <= 1'b1; prog_busy <= 1'b1; end
			if (prog_wr && prog_ack) prog_wr <= 1'b0;
			if (prog_busy && !prog_wr && prog_rdy) begin prog_busy <= 1'b0; prog_seen <= prog_req_t; prog_ack_t <= ~prog_ack_t; end
		end
	end

	// ------------------------------------------------ the data
	wire [3:0]  dst, dok, rdy;
	wire [15:0] dout;
	genvar gb;
	generate for (gb = 0; gb < 4; gb = gb + 1) begin : g_bank
		reg [1:0]  widx;
		reg [47:0] acc;                 // the burst's first three words
		always @(posedge clk_sd) begin
			if (rst) begin widx <= 0; valid_t[gb] <= 1'b0; end
			else if (dok[gb]) begin
				case (widx)
					2'd0: acc[15:0]  <= dout;
					2'd1: acc[31:16] <= dout;
					2'd2: acc[47:32] <= dout;
					default: ;
				endcase
				widx <= widx + 1'd1;
				if (rdy[gb]) begin
					widx <= 0;
					valid_t[gb] <= ~valid_t[gb];
					case (gb)
						0: data0 <= {dout, acc};
						1: data1 <= {dout, acc};
						2: data2 <= {dout, acc};
						default: data3 <= {dout, acc};
					endcase
				end
			end
		end
	end endgenerate

`ifdef NS2_SDRAM_TRACE
	always @(posedge clk_sd) if (dst | dok | rdy) $display("sd: dst %b dok %b rdy %b dout %h", dst, dok, rdy, dout);
`endif
	jtframe_sdram64 #(.AW(22), .HF(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(16),
	                  .BA0_WEN(0), .MISTER(1), .RFSHCNT(9), .BAPRIO(1)) u_ctl (
		.rst(rst), .clk(clk_sd), .init(init),
		.ba0_addr(qa[0]), .ba1_addr(qa[1]), .ba2_addr(qa[2]), .ba3_addr(qa[3]),
		.rd(rd), .wr(4'd0),
		.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
		.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
		.prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr), .prog_din(prog_din), .prog_dsn(prog_dsn),
		.prog_ba(prog_ba), .prog_dst(), .prog_dok(), .prog_rdy(prog_rdy), .prog_ack(prog_ack),
		.rfsh(rfsh), .ack(ack), .dst(dst), .dok(dok), .rdy(rdy), .dout(dout),
		.sdram_dq(SDRAM_DQ),
`ifdef VERILATOR
		.sdram_din(sdram_din),
`endif
		.sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
		.sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS), .sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE));
endmodule
