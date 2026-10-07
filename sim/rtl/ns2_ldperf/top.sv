// The ROM download path end to end (NS2-39): ddr_rom_load replaying a DDR3
// image into ns2_mem, its writes through ns2_sdram into the burst SDRAM model.
// tb.cpp plays hps_io's DDR3-mode download and the DDR3 port, counts clocks
// per image word and hashes the SDRAM afterwards.
module top (
	input             clk,
	input             clk_sd,
	input             rst,
	input             h_download,
	input      [26:0] h_addr,
	output            h_wait,
	output            active,
	output            ddr_rd,
	output     [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	input      [2:0]  board,
	input             mh_wiring,
	input             lw_wiring,
	output     [31:0] violations,
	output     [31:0] n_wr
);
	wire        c_download, c_wr, c_wait;
	wire [15:0] c_index, c_dout;
	wire [26:0] c_addr;
	ddr_rom_load #(.DW(16), .GAP(`GAP)) ld (.clk(clk),
		.h_download(h_download), .h_index(16'd0), .h_wr(1'b0), .h_addr(h_addr), .h_dout(16'd0), .h_wait(h_wait),
		.c_download(c_download), .c_index(c_index), .c_wr(c_wr), .c_addr(c_addr), .c_dout(c_dout), .c_wait(c_wait),
		.active(active), .clk_ddr(clk_sd), .ddr_busy(1'b0), .hold(1'b0), .ddr_rd(ddr_rd), .ddr_pending(),
		.ddr_addr(ddr_addr), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready));
	wire dl_rom = c_download && c_index == 16'd0;
	wire dl_wait;
	assign c_wait = dl_rom & dl_wait;
	reg [31:0] nw = 0;
	always @(posedge clk) if (dl_rom && c_wr) nw <= nw + 1;
	assign n_wr = nw;

	wire [21:0] prog_addr, sd_addr0, sd_addr1, sd_addr2, sd_addr3;
	wire [1:0]  prog_ba, prog_dsn;
	wire [15:0] prog_din;
	wire        prog_req_t, prog_ack_t;
	wire [3:0]  sd_push, sd_full, sd_valid_t, sd_push_we;
	wire [63:0] sd_push_din, sd_data0, sd_data1, sd_data2, sd_data3;
	wire [7:0]  sd_push_dsn;
	/* verilator lint_off PINMISSING */
	ns2_mem #(.WRAM_SD(0)) mem (.clk(clk), .rst(rst), .board(board), .mh_wiring(mh_wiring), .lw_wiring(lw_wiring), .drom_empty(2'b00),
		.dl(dl_rom), .dl_wr(dl_rom & c_wr), .dl_addr(c_addr[24:0]), .dl_data(c_dout), .dl_wait(dl_wait),
		.tile_req(1'b0), .tmask_req(1'b0), .roz_req(1'b0), .c169_req(1'b0), .c169m_req(1'b0), .spr_req(1'b0),
		.mprog_req(1'b0), .sprog_req(1'b0), .drom_req(1'b0), .aud_req(1'b0), .mcu_req(1'b0), .c140_req(1'b0),
		.wram_req(3'b000), .wram_we(3'b000),
		.sd_push_we(sd_push_we), .sd_push_din(sd_push_din), .sd_push_dsn(sd_push_dsn),
		.sd_addr0(sd_addr0), .sd_addr1(sd_addr1), .sd_addr2(sd_addr2), .sd_addr3(sd_addr3),
		.sd_push(sd_push), .sd_full(sd_full), .sd_valid_t(sd_valid_t),
		.sd_data0(sd_data0), .sd_data1(sd_data1), .sd_data2(sd_data2), .sd_data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t));
	/* verilator lint_on PINMISSING */

	// refresh as NamcoS2.sv makes it while the board is in reset
	reg [11:0] rf_cnt = 0;
	reg        sd_rfsh = 1'b0;
	always @(posedge clk) begin
		rf_cnt  <= rf_cnt == 12'd3071 ? 12'd0 : rf_cnt + 12'd1;
		sd_rfsh <= rf_cnt >= 12'd2400;
	end
	wire [15:0] dq_q, sdram_din, dq;
	wire        dq_oe;
	wire [12:0] a;
	wire [1:0]  ba;
	wire        dqml, dqmh, nwe, ncas, nras, ncs, cke;
	assign dq = dq_oe ? dq_q : sdram_din;
	ns2_sdram #(.WEN(4'b0000), .CL(3), .XRC(1)) u_sd (.clk(clk), .clk_sd(clk_sd), .rst(rst), .init(), .rfsh(sd_rfsh),
		.addr0(sd_addr0), .addr1(sd_addr1), .addr2(sd_addr2), .addr3(sd_addr3), .push(sd_push), .req_full(sd_full), .valid_t(sd_valid_t),
		.push_we(sd_push_we), .push_din(sd_push_din), .push_dsn(sd_push_dsn),
		.data0(sd_data0), .data1(sd_data1), .data2(sd_data2), .data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_en(dl_rom),
		.prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t),
		.SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(ba), .SDRAM_nWE(nwe),
		.SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nCS(ncs), .SDRAM_CKE(cke), .sdram_din(sdram_din));
	sdram_model_burst #(.TCK_NS(10.1725)) u_mem (.SDRAM_CLK(clk_sd), .SDRAM_A(a), .SDRAM_BA(ba), .DQ_IN(sdram_din), .DQ_Q(dq_q), .DQ_OE(dq_oe),
		.SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs), .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras),
		.SDRAM_nWE(nwe), .SDRAM_CKE(cke), .violations(violations));
endmodule
