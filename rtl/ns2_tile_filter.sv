// The C123's tile and mask streams over the SDRAM (M3, docs/PLAN.md 2.3,
// NS2-3's additions): what bank 2 cannot serve every line.
// - The tile class table (2 bits a tile code, from the mask ROM at the
//   download: 0 transparent, 1 opaque, 2 mixed). A transparent tile needs
//   neither its row nor its mask; an opaque one no mask.
// - A tile-row cache (256 bursts, direct-mapped) and a mask cache (256
//   tiles' 8 mask bytes, direct-mapped by code).
// Each stream answers in request order (ns2_c123's contract) through a queue
// of 16 entries. An entry is ready at once (the class, a hit) or when its
// burst returns: the misses are fetched in queue order, several in flight,
// and the bursts come back in that order.
// A tile request carries the tile (TilemapCB's bitswap of the code); the
// class table is indexed by the code, so the swap is undone here.
module ns2_tile_filter (
	input             clk,
	input             rst,
	input             tile_fl2,       // finalap2 / finalap3: TilemapCB_finalap2
	// the class table's load (the download)
	input             class_we,
	input      [15:0] class_addr,
	input      [1:0]  class_data,
	// the C123's streams
	input             t_req,
	input      [18:0] t_addr,         // burst: tile * 8 + row
	output reg        t_ack,
	output reg        t_valid,
	output reg [63:0] t_data,
	input             m_req,
	input      [18:0] m_addr,         // byte: code * 8 + row
	output reg        m_ack,
	output reg        m_valid,
	output reg [7:0]  m_data,
	// the SDRAM's (ns2_mem, bank 2)
	output reg        dt_req,
	output reg [18:0] dt_addr,
	input             dt_ack,
	input             dt_valid,
	input      [63:0] dt_data,
	output reg        dm_req,
	output reg [15:0] dm_addr,        // a code: its 8 mask bytes, one burst
	input             dm_ack,
	input             dm_valid,
	input      [63:0] dm_data,
	// statistics (simulation)
	output reg [31:0] n_t, n_t_miss, n_m, n_m_miss
);
	// TilemapCB undone: tile [15:11] = code {13, 12, 11, 15, 14} (standard),
	// tile [14:11] = code {13, 12, 11, 14} (finalap2)
	function [15:0] code_of(input [15:0] t);
		code_of = tile_fl2 ? {1'b0, t[11], t[14], t[13], t[12], t[10:0]}
		                   : {t[12], t[11], t[15], t[14], t[13], t[10:0]};
	endfunction

	// ================================================ the tile stream
	reg [63:0] tc_d [0:255];
	reg [10:0] tc_t [0:255];
	reg [255:0] tc_v;
	reg [63:0] tq_d [0:15];            // the queue: data, ready, the burst
	reg [15:0] tq_r;
	reg [18:0] tq_a [0:15];
	reg [4:0]  tq_w, tq_h;
	wire       tq_full = (tq_w ^ tq_h) == 5'b10000;
	(* ramstyle = "logic" *) reg [3:0]  ti_q [0:15];            // the misses to fetch (entry indices), in order
	reg [4:0]  ti_w, ti_r;
	(* ramstyle = "logic" *) reg [3:0]  tf_q [0:15];            // the fetches in flight, in order
	reg [4:0]  tf_w, tf_r;
	reg [1:0]  ts;
	reg [18:0] ta;
	reg [63:0] tcd;
	reg [10:0] tct;
	reg        tcv;
	always @(posedge clk) begin
		t_ack <= 1'b0; t_valid <= 1'b0;
		if (rst) begin
			ts <= 0; tq_w <= 0; tq_h <= 0; tq_r <= 0; tc_v <= 0; dt_req <= 1'b0;
			ti_w <= 0; ti_r <= 0; tf_w <= 0; tf_r <= 0; n_t <= 0; n_t_miss <= 0;
		end else begin
			// the lookup: accept, read the class and the cache, decide
			case (ts)
				2'd0: if (t_req && !t_ack && !tq_full) begin ta <= t_addr; t_ack <= 1'b1; ts <= 2'd1; end
				2'd1: begin
					tcd <= tc_d[ta[7:0]]; tct <= tc_t[ta[7:0]]; tcv <= tc_v[ta[7:0]];
					ts <= 2'd2;
				end
				default: begin
					tq_a[tq_w[3:0]] <= ta;
					n_t <= n_t + 1'd1;
					if (tcls == 2'd0) begin tq_d[tq_w[3:0]] <= 64'd0; tq_r[tq_w[3:0]] <= 1'b1; end
					else if (tcv && tct == ta[18:8]) begin tq_d[tq_w[3:0]] <= tcd; tq_r[tq_w[3:0]] <= 1'b1; end
					else begin
						tq_r[tq_w[3:0]] <= 1'b0;
						ti_q[ti_w[3:0]] <= tq_w[3:0]; ti_w <= ti_w + 1'd1;
						n_t_miss <= n_t_miss + 1'd1;
					end
					tq_w <= tq_w + 1'd1;
					ts <= 2'd0;
				end
			endcase
			// the fetches: the next miss, as the SDRAM takes them
			if (!dt_req && ti_r != ti_w) begin
				dt_req <= 1'b1; dt_addr <= tq_a[ti_q[ti_r[3:0]]];
				tf_q[tf_w[3:0]] <= ti_q[ti_r[3:0]]; tf_w <= tf_w + 1'd1; ti_r <= ti_r + 1'd1;
			end
			if (dt_req && dt_ack) dt_req <= 1'b0;
			// the bursts back: the oldest fetch
			if (dt_valid) begin
				tq_d[tf_q[tf_r[3:0]]] <= dt_data; tq_r[tf_q[tf_r[3:0]]] <= 1'b1;
				tc_d[tq_a[tf_q[tf_r[3:0]]][7:0]] <= dt_data; tc_t[tq_a[tf_q[tf_r[3:0]]][7:0]] <= tq_a[tf_q[tf_r[3:0]]][18:8];
				tc_v[tq_a[tf_q[tf_r[3:0]]][7:0]] <= 1'b1;
				tf_r <= tf_r + 1'd1;
			end
			// the head, in order
			if (tq_h != tq_w && tq_r[tq_h[3:0]]) begin
				t_valid <= 1'b1; t_data <= tq_d[tq_h[3:0]]; tq_h <= tq_h + 1'd1;
				tq_r[tq_h[3:0]] <= 1'b0;
			end
		end
	end

`ifdef VERILATOR
	// debug (simulation): tile misses' latency, request to burst (a FIFO of
	// issue times), and the clocks the queue was full
	reg [31:0] dbg_lat /*verilator public_flat_rd*/, dbg_nlat /*verilator public_flat_rd*/, dbg_full /*verilator public_flat_rd*/;
	reg [31:0] dbg_clk;
	reg [31:0] dbg_t0 [0:15];
	reg [3:0]  dbg_w, dbg_r;
	initial begin dbg_lat = 0; dbg_nlat = 0; dbg_full = 0; dbg_clk = 0; dbg_w = 0; dbg_r = 0; end
	always @(posedge clk) begin
		dbg_clk <= dbg_clk + 1;
		if (!dt_req && ti_r != ti_w) begin dbg_t0[dbg_w] <= dbg_clk; dbg_w <= dbg_w + 1'd1; end
		if (dt_valid) begin dbg_lat <= dbg_lat + (dbg_clk - dbg_t0[dbg_r]); dbg_nlat <= dbg_nlat + 1; dbg_r <= dbg_r + 1'd1; end
		if (tq_full) dbg_full <= dbg_full + 1;
	end
`endif

	// ================================================ the mask stream
	reg [63:0] mc_d [0:255];
	reg [7:0]  mc_t [0:255];
	reg [255:0] mc_v;
	reg [7:0]  mq_d [0:15];
	reg [15:0] mq_r;
	reg [18:0] mq_a [0:15];
	reg [4:0]  mq_w, mq_h;
	wire       mq_full = (mq_w ^ mq_h) == 5'b10000;
	(* ramstyle = "logic" *) reg [3:0]  mi_q [0:15];
	reg [4:0]  mi_w, mi_r;
	(* ramstyle = "logic" *) reg [3:0]  mf_q [0:15];
	reg [4:0]  mf_w, mf_r;
	reg [1:0]  ms;
	reg [18:0] ma;
	reg [63:0] mcd;
	reg [7:0]  mct;
	reg        mcv;

	// ------------------------------------------------ the class table
	// two ports: the load shares the tile stream's (the download is in
	// reset); each stream's lookup reads it the clock after the address
	reg [1:0]  cls [0:65535];
	wire [15:0] cls_ta = class_we ? class_addr : code_of(ta[18:3]);
	reg  [1:0]  tcls, mcls;
	always @(posedge clk)
		if (class_we) begin cls[cls_ta] <= class_data; tcls <= class_data; end
		else tcls <= cls[cls_ta];
	always @(posedge clk) mcls <= cls[ma[18:3]];

	always @(posedge clk) begin
		m_ack <= 1'b0; m_valid <= 1'b0;
		if (rst) begin
			ms <= 0; mq_w <= 0; mq_h <= 0; mq_r <= 0; mc_v <= 0; dm_req <= 1'b0;
			mi_w <= 0; mi_r <= 0; mf_w <= 0; mf_r <= 0; n_m <= 0; n_m_miss <= 0;
		end else begin
			case (ms)
				2'd0: if (m_req && !m_ack && !mq_full) begin ma <= m_addr; m_ack <= 1'b1; ms <= 2'd1; end
				2'd1: begin
					mcd <= mc_d[ma[10:3]]; mct <= mc_t[ma[10:3]]; mcv <= mc_v[ma[10:3]];
					ms <= 2'd2;
				end
				default: begin
					mq_a[mq_w[3:0]] <= ma;
					n_m <= n_m + 1'd1;
					if (mcls == 2'd0) begin mq_d[mq_w[3:0]] <= 8'h00; mq_r[mq_w[3:0]] <= 1'b1; end
					else if (mcls == 2'd1) begin mq_d[mq_w[3:0]] <= 8'hff; mq_r[mq_w[3:0]] <= 1'b1; end
					else if (mcv && mct == ma[18:11]) begin mq_d[mq_w[3:0]] <= mcd[8 * ma[2:0] +: 8]; mq_r[mq_w[3:0]] <= 1'b1; end
					else begin
						mq_r[mq_w[3:0]] <= 1'b0;
						mi_q[mi_w[3:0]] <= mq_w[3:0]; mi_w <= mi_w + 1'd1;
						n_m_miss <= n_m_miss + 1'd1;
					end
					mq_w <= mq_w + 1'd1;
					ms <= 2'd0;
				end
			endcase
			if (!dm_req && mi_r != mi_w) begin
				dm_req <= 1'b1; dm_addr <= mq_a[mi_q[mi_r[3:0]]][18:3];
				mf_q[mf_w[3:0]] <= mi_q[mi_r[3:0]]; mf_w <= mf_w + 1'd1; mi_r <= mi_r + 1'd1;
			end
			if (dm_req && dm_ack) dm_req <= 1'b0;
			if (dm_valid) begin
				mq_d[mf_q[mf_r[3:0]]] <= dm_data[8 * mq_a[mf_q[mf_r[3:0]]][2:0] +: 8]; mq_r[mf_q[mf_r[3:0]]] <= 1'b1;
				mc_d[mq_a[mf_q[mf_r[3:0]]][10:3]] <= dm_data; mc_t[mq_a[mf_q[mf_r[3:0]]][10:3]] <= mq_a[mf_q[mf_r[3:0]]][18:11];
				mc_v[mq_a[mf_q[mf_r[3:0]]][10:3]] <= 1'b1;
				mf_r <= mf_r + 1'd1;
			end
			if (mq_h != mq_w && mq_r[mq_h[3:0]]) begin
				m_valid <= 1'b1; m_data <= mq_d[mq_h[3:0]]; mq_h <= mq_h + 1'd1;
				mq_r[mq_h[3:0]] <= 1'b0;
			end
		end
	end
endmodule
