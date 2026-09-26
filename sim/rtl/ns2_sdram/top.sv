// ns2_sdram against the burst SDRAM model (M3): the download's writes, then
// every bank's reads from the core's clock, checked word for word.
module top (
	input             clk,
	input             clk_sd,
	input             rst,
	input             rfsh,
	output            init,
	input      [21:0] addr0, addr1, addr2, addr3,
	input      [3:0]  push,
	output     [3:0]  req_full, valid_t,
	output     [63:0] data0, data1, data2, data3,
	input      [21:0] prog_addr,
	input      [1:0]  prog_ba,
	input      [15:0] prog_din,
	input      [1:0]  prog_dsn,
	input             prog_en,
	input             prog_req_t,
	output            prog_ack_t,
	output     [31:0] violations
);
	wire [15:0] dq_q, sdram_din, dq;
	wire        dq_oe;
	wire [12:0] a;
	wire [1:0]  ba;
	wire        dqml, dqmh, nwe, ncas, nras, ncs, cke;
	assign dq = dq_oe ? dq_q : sdram_din;
	ns2_sdram u_sd (.clk(clk), .clk_sd(clk_sd), .rst(rst), .init(init), .rfsh(rfsh),
		.addr0(addr0), .addr1(addr1), .addr2(addr2), .addr3(addr3), .push(push), .req_full(req_full), .valid_t(valid_t),
		.data0(data0), .data1(data1), .data2(data2), .data3(data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_en(prog_en),
		.prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t),
		.SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(ba), .SDRAM_nWE(nwe),
		.SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nCS(ncs), .SDRAM_CKE(cke), .sdram_din(sdram_din));
	sdram_model_burst #(.TCK_NS(10.1725)) u_mem (.SDRAM_CLK(clk_sd), .SDRAM_A(a), .SDRAM_BA(ba), .DQ_IN(sdram_din), .DQ_Q(dq_q), .DQ_OE(dq_oe),
		.SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs), .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras),
		.SDRAM_nWE(nwe), .SDRAM_CKE(cke), .violations(violations));
endmodule
