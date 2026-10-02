// D3's bandwidth probe (docs/PLAN.md 2.3, M0): jtframe_sdram64 at 96 MHz
// against sim/models/sdram_model_burst.sv, four request generators, one per
// bank. Each generator saturates its bank or issues at a fixed cadence (a
// request falls due every P clocks; the backlog shows whether it keeps up),
// with sequential, random or replayed addresses (tools/ns2_load.py --dump:
// the fetches of captured MAME frames). Every word is checked against the
// preloaded pattern (mem[word] = word address hash), so the probe also proves
// the data path: it found the PRE_RD fix in jtframe_sdram64_bank.v.
module probe_top #(parameter BAPRIO = 1, parameter CL = 2, parameter XRC = 0) (
	input             clk,
	input             rst,
	input             rfsh,
	input      [3:0]  enable,       // generator on per bank
	input      [15:0] period0, period1, period2, period3,   // clocks per request, fixed cadence (0 = saturate)
	input      [3:0]  pattern,      // per bank: 1 = random addresses, 0 = sequential
	input      [3:0]  replay,       // per bank: 1 = replay rp[] (the tb loads it), overrides pattern
	input      [31:0] rp_len0, rp_len1, rp_len2, rp_len3,
	output     [31:0] done0, done1, done2, done3,
	output     [31:0] lat_sum0, lat_sum1, lat_sum2, lat_sum3,
	output     [31:0] lat_max0, lat_max1, lat_max2, lat_max3,
	output     [31:0] backlog0, backlog1, backlog2, backlog3,   // most requests ever owed
	output     [31:0] owed0, owed1, owed2, owed3,               // requests owed at the end
	output reg [31:0] bad_words,
	output     [31:0] violations,
	output            init,         // high while the controller initialises
	output     [15:0] dbg_dout,
	output     [3:0]  dbg_dok, dbg_ack, dbg_dst, dbg_rdy,
	output     [21:0] dbg_addr0
);
	assign dbg_dout = dout; assign dbg_dok = dok; assign dbg_ack = ack; assign dbg_dst = dst; assign dbg_rdy = rdy; assign dbg_addr0 = addr[0];
	localparam AW = 22;
	wire [AW-1:0] addr [0:3];
	wire [3:0]    rd;
	wire [3:0]    ack, dst, dok, rdy;
	wire [15:0]   dout;
	wire [12:0]   sdram_a;
	wire [1:0]    sdram_ba;
	wire [15:0]   sdram_din, dq_q, dq;
	wire          dq_oe, dqml, dqmh, nwe, ncas, nras, ncs, cke;
	assign dq = dq_oe ? dq_q : sdram_din;

	jtframe_sdram64 #(.AW(AW), .HF(1), .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64),
	                  .BA0_WEN(0), .MISTER(1), .RFSHCNT(9), .BAPRIO(BAPRIO), .CL(CL), .XRC(XRC)) u_ctl (
		.rst(rst), .clk(clk), .init(init),
		.ba0_addr(addr[0]), .ba1_addr(addr[1]), .ba2_addr(addr[2]), .ba3_addr(addr[3]),
		.rd(rd), .wr(4'd0),
		.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
		.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
		.prog_en(1'b0), .prog_addr('0), .prog_rd(1'b0), .prog_wr(1'b0), .prog_din(16'd0), .prog_dsn(2'b11),
		.prog_ba(2'd0), .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
		.rfsh(rfsh), .ack(ack), .dst(dst), .dok(dok), .rdy(rdy), .dout(dout),
		.sdram_dq(dq), .sdram_din(sdram_din), .sdram_a(sdram_a), .sdram_dqml(dqml), .sdram_dqmh(dqmh),
		.sdram_ba(sdram_ba), .sdram_nwe(nwe), .sdram_ncas(ncas), .sdram_nras(nras), .sdram_ncs(ncs), .sdram_cke(cke));

	sdram_model_burst u_mem (
		.SDRAM_CLK(clk), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba), .DQ_IN(sdram_din), .DQ_Q(dq_q), .DQ_OE(dq_oe),
		.SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs), .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras),
		.SDRAM_nWE(nwe), .SDRAM_CKE(cke), .violations(violations));

	// the word each bank should return next: its request's address + burst index
	wire [15:0] per [0:3];
	assign per[0] = period0; assign per[1] = period1; assign per[2] = period2; assign per[3] = period3;
	reg [31:0] done [0:3], lsum [0:3], lmax [0:3];
	assign done0 = done[0]; assign done1 = done[1]; assign done2 = done[2]; assign done3 = done[3];
	assign lat_sum0 = lsum[0]; assign lat_sum1 = lsum[1]; assign lat_sum2 = lsum[2]; assign lat_sum3 = lsum[3];
	assign lat_max0 = lmax[0]; assign lat_max1 = lmax[1]; assign lat_max2 = lmax[2]; assign lat_max3 = lmax[3];
	reg [AW-1:0] a_r [0:3], a_cur [0:3];
	reg [3:0]    rd_r;
	// replayed address streams (tools/ns2_load.py --dump): bank g's at g * RPN
	localparam RPN = 1 << 18;
	reg [AW-1:0] rp [0:4*RPN-1] /*verilator public_flat_rw*/;
	reg [31:0]   ridx [0:3];
	wire [31:0]  rlen [0:3];
	assign rlen[0] = rp_len0; assign rlen[1] = rp_len1; assign rlen[2] = rp_len2; assign rlen[3] = rp_len3;
	reg [31:0]   lat [0:3], wait_cnt [0:3], lfsr [0:3], tokens [0:3], bmax [0:3];
	assign backlog0 = bmax[0]; assign backlog1 = bmax[1]; assign backlog2 = bmax[2]; assign backlog3 = bmax[3];
	assign owed0 = tokens[0]; assign owed1 = tokens[1]; assign owed2 = tokens[2]; assign owed3 = tokens[3];
	reg [1:0]    widx [0:3];
	assign rd = rd_r;
	assign addr[0] = a_r[0]; assign addr[1] = a_r[1]; assign addr[2] = a_r[2]; assign addr[3] = a_r[3];
	integer g;
	// one always block for all four generators (four generate blocks writing
	// elements of one unpacked array is multi-driven to Verilator)
	always @(posedge clk) begin
		for (g = 0; g < 4; g = g + 1) begin
			if (rst || init) begin
				rd_r[g] <= 1'b0; done[g] <= 0; lsum[g] <= 0; lmax[g] <= 0; lat[g] <= 0; wait_cnt[g] <= 0; tokens[g] <= 0; bmax[g] <= 0;
				lfsr[g] <= 32'h1234567 * (g + 1); a_r[g] <= 0; widx[g] <= 0; ridx[g] <= 0;
			end else begin
				if (rd_r[g] || lat[g] != 0) lat[g] <= lat[g] + 1;
				// a request falls due every per[g] clocks; the generator issues
				// the oldest owed one as soon as the bank is free
				begin : cadence
					reg due, issue;
					due   = per[g] != 0 && enable[g] && wait_cnt[g] + 1 >= {16'd0, per[g]};
					issue = !rd_r[g] && lat[g] == 0 && enable[g] && (per[g] == 0 || tokens[g] != 0);
					wait_cnt[g] <= due ? 0 : wait_cnt[g] + 1;
					tokens[g] <= tokens[g] + due - (issue && per[g] != 0);
					if (tokens[g] > bmax[g]) bmax[g] <= tokens[g];
				end
				if (!rd_r[g] && lat[g] == 0 && enable[g] && (per[g] == 0 || tokens[g] != 0)) begin
					begin
						lfsr[g] <= {lfsr[g][30:0], lfsr[g][31] ^ lfsr[g][21] ^ lfsr[g][1] ^ lfsr[g][0]};
						a_r[g] <= replay[g] ? rp[g * RPN + ridx[g]] :
						          pattern[g] ? {lfsr[g][AW-1:2], 2'b00} : a_r[g] + 4;
						if (replay[g]) ridx[g] <= ridx[g] + 1 == rlen[g] ? 0 : ridx[g] + 1;
						rd_r[g] <= 1'b1; lat[g] <= 1;
					end
				end
				if (rd_r[g] && ack[g]) begin rd_r[g] <= 1'b0; a_cur[g] <= a_r[g]; widx[g] <= 0; end
				if (dok[g]) widx[g] <= widx[g] + 1;
				if (rdy[g]) begin
					done[g] <= done[g] + 1; lsum[g] <= lsum[g] + lat[g];
					if (lat[g] > lmax[g]) lmax[g] <= lat[g];
					lat[g] <= 0;
				end
			end
		end
	end

	// data check: the model holds mem[{bank, word}] = hash of that word address
	function [15:0] hash(input [1:0] b, input [AW-1:0] w);
		hash = w[15:0] ^ {w[21:16], b, 8'h5a};
	endfunction
	integer k;
	reg [31:0] tck = 0;
	always @(posedge clk) tck <= tck + 1;
	always @(posedge clk) begin
		if (rst) bad_words <= 0;
		else for (k = 0; k < 4; k = k + 1)
			if (dok[k] && dout != hash(k[1:0], a_cur[k] + widx[k])) begin
				bad_words <= bad_words + 1;
				if (bad_words < 6) $display("bad t=%0d: bank %0d a_cur %h widx %0d dout %h want %h dok %b", tck, k, a_cur[k], widx[k], dout, hash(k[1:0], a_cur[k] + widx[k]), dok);
			end
	end
endmodule
