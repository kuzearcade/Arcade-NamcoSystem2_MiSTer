// The SDRAM (M3, docs/PLAN.md 2.3): jtframe_sdram64 at clk_sd (98.304 MHz,
// twice clk), four banks of 64-bit read bursts and the download's writes.
// The core runs at clk (49.152 MHz); the two clocks come from one PLL, in
// phase, so each crossing is a register-to-register path of one fast period:
// - requests: a four-entry FIFO per bank, written at clk (push with the
//   address when req_full is low), read at clk_sd: the controller always has
//   the next address when it accepts one. The pointers cross in Gray code,
//   each through a register of the other clock: clk_sd sees a request only a
//   clk_sd edge after the write, so the controller never takes an entry on
//   the edge it is written (clk_sd's network reaches its registers about
//   1 ns after clk's; NamcoS2.sdc relaxes those paths' hold by that edge,
//   NS2-20);
// - data: the fast side gathers a burst's four words (bytes n at [8n +: 8]
//   of the 64 bits, the ROM's order) and toggles valid_t; the register holds
//   until the bank's next burst, at least two core clocks later.
// Bursts return in request order within a bank.
// The download writes 16-bit words through the controller's programming
// port: set prog_*, toggle prog_req_t, wait for prog_ack_t to follow.
// rfsh: the core asks for a round of refreshes (in hblank).
// WEN: the banks that take writes (the NB bitstream's work RAMs, bank 1): a
// request pushed with push_we writes one 16-bit word (its mask active low)
// and returns nothing.
module ns2_sdram #(parameter [3:0] WEN = 4'b0000) (
	input             clk,
	input             clk_sd,
	input             rst,
	output            init,           // high while the controller initialises (clk_sd domain)
	input             rfsh,
	// the banks: requests at clk, data back with a toggle
	input      [21:0] addr0, addr1, addr2, addr3,   // 16-bit words
	input      [3:0]  push,           // one clk strobe per request, the address with it
	input      [3:0]  push_we,        // WEN banks: the request is a write
	input      [63:0] push_din,       // its word, 16 bits a bank
	input      [7:0]  push_dsn,       // its byte mask, 2 bits a bank
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
	wire [3:0]  rd, wr;
	wire [21:0] qa [0:3];
	wire [15:0] qd [0:3];
	wire [1:0]  qm [0:3];
	wire [21:0] ain [0:3];
	assign ain[0] = addr0; assign ain[1] = addr1; assign ain[2] = addr2; assign ain[3] = addr3;
	genvar gq;
	generate for (gq = 0; gq < 4; gq = gq + 1) begin : g_req
		reg [21:0] q [0:3];
		reg [2:0]  wp;                  // clk domain
		reg [2:0]  rp;                  // clk_sd domain
		// the pointers in Gray code, and each as the other clock sees it
		reg [2:0]  wp_g, rp_g;          // clk, clk_sd
		reg [2:0]  wp_g_sd;             // wp_g at clk_sd
		reg [2:0]  rp_g_s;              // rp_g at clk
		wire [2:0] wp_n = wp + 1'd1;
		always @(posedge clk)
			if (rst) begin wp <= 0; wp_g <= 0; rp_g_s <= 0; end
			else begin
				if (push[gq] && !req_full[gq]) begin q[wp[1:0]] <= ain[gq]; wp <= wp_n; wp_g <= wp_n ^ (wp_n >> 1); end
				rp_g_s <= rp_g;
			end
		// full against the read pointer clk last saw: late, so never too full
		wire [2:0] rp_s = {rp_g_s[2], rp_g_s[2] ^ rp_g_s[1], rp_g_s[2] ^ rp_g_s[1] ^ rp_g_s[0]};
		assign req_full[gq] = (wp ^ rp_s) == 3'b100;
		// rd (or wr) while the FIFO holds a request, as clk_sd sees the write
		// pointer; the acceptance pops it, and the controller's bank stays
		// busy past it, so the next address is taken only once the bank is
		// ready
		wire       pend = wp_g_sd != rp_g;
		wire       we;
		if (WEN[gq]) begin : g_w
			reg        q_we [0:3];
			reg [15:0] q_d  [0:3];
			reg [1:0]  q_m  [0:3];
			always @(posedge clk)
				if (push[gq] && !req_full[gq]) begin
					q_we[wp[1:0]] <= push_we[gq]; q_d[wp[1:0]] <= push_din[16 * gq +: 16]; q_m[wp[1:0]] <= push_dsn[2 * gq +: 2];
				end
			assign we = q_we[rp[1:0]];
			assign qd[gq] = q_d[rp[1:0]];
			assign qm[gq] = q_m[rp[1:0]];
		end else begin : g_r
			assign we = 1'b0;
			assign qd[gq] = 16'd0;
			assign qm[gq] = 2'b11;
		end
		assign rd[gq] = pend && !we;
		assign wr[gq] = pend && we;
		assign qa[gq] = q[rp[1:0]];
		wire [2:0] rp_n = rp + 1'd1;
		always @(posedge clk_sd)
			if (rst) begin rp <= 0; rp_g <= 0; wp_g_sd <= 0; end
			else begin
				wp_g_sd <= wp_g;
				if (ack[gq] && pend) begin rp <= rp_n; rp_g <= rp_n ^ (rp_n >> 1); end
			end
	end endgenerate

`ifdef VERILATOR
	// debug (simulation): requests accepted per bank, and clk_sd cycles with
	// burst data on the bus (dok)
	reg [31:0] dbg_acc0 /*verilator public_flat_rd*/, dbg_acc1 /*verilator public_flat_rd*/,
	           dbg_acc2 /*verilator public_flat_rd*/, dbg_acc3 /*verilator public_flat_rd*/, dbg_dok /*verilator public_flat_rd*/;
	initial begin dbg_acc0 = 0; dbg_acc1 = 0; dbg_acc2 = 0; dbg_acc3 = 0; dbg_dok = 0; end
	always @(posedge clk_sd) begin
		if (ack[0] && (rd[0] || wr[0])) dbg_acc0 <= dbg_acc0 + 1;
		if (ack[1] && (rd[1] || wr[1])) dbg_acc1 <= dbg_acc1 + 1;
		if (ack[2] && (rd[2] || wr[2])) dbg_acc2 <= dbg_acc2 + 1;
		if (ack[3] && (rd[3] || wr[3])) dbg_acc3 <= dbg_acc3 + 1;
		if (|dok) dbg_dok <= dbg_dok + 1;
	end
`endif

	// ------------------------------------------------ the download
	// prog_en changes only as a download starts and ends, with no write in
	// flight: two flops into clk_sd take the combinational path from the
	// download's index decode off the controller's command mux (NS2-14)
	reg [1:0] prog_en_s;
	always @(posedge clk_sd) prog_en_s <= {prog_en_s[0], prog_en};
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
	                  .BA0_WEN(WEN[0]), .BA1_WEN(WEN[1]), .BA2_WEN(WEN[2]), .BA3_WEN(WEN[3]),
	                  .MISTER(1), .RFSHCNT(9), .BAPRIO(1)) u_ctl (
		.rst(rst), .clk(clk_sd), .init(init),
		.ba0_addr(qa[0]), .ba1_addr(qa[1]), .ba2_addr(qa[2]), .ba3_addr(qa[3]),
		.rd(rd), .wr(wr),
		.ba0_din(qd[0]), .ba0_dsn(qm[0]), .ba1_din(qd[1]), .ba1_dsn(qm[1]),
		.ba2_din(qd[2]), .ba2_dsn(qm[2]), .ba3_din(qd[3]), .ba3_dsn(qm[3]),
		.prog_en(prog_en_s[1]), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr), .prog_din(prog_din), .prog_dsn(prog_dsn),
		.prog_ba(prog_ba), .prog_dst(), .prog_dok(), .prog_rdy(prog_rdy), .prog_ack(prog_ack),
		.rfsh(rfsh), .ack(ack), .dst(dst), .dok(dok), .rdy(rdy), .dout(dout),
		.sdram_dq(SDRAM_DQ),
`ifdef VERILATOR
		.sdram_din(sdram_din),
`endif
		.sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
		.sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS), .sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE));
endmodule
