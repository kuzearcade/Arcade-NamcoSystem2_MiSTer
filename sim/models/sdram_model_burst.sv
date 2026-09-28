// Behavioural SDR SDRAM model with bursts, for the D3 bandwidth probe and
// for any controller that programs the mode register (jtframe_sdram64):
// MT48LC16M16A2-style, 4 banks x 8192 rows x 512 columns x 16 bits (32 MB).
//
//   - LOAD MODE: burst length A[2:0] (1/2/4/8), CAS latency A[6:4] (2/3),
//     write burst mode A9 (1: single-location writes, as jtframe_sdram64 sets)
//   - READ: BL words from CL clocks after the command, column wrapping within
//     the burst; WRITE: BL words from the command clock, DQML/DQMH mask bytes
//   - timing checks at the model's clock (tCK): tRCD, tRP, tRAS, tRC, tRRD,
//     reading a closed bank, activating an open one. Each violation is counted
//     (and the first few are printed): a controller that passes the probe
//     with violations has not passed it.
module sdram_model_burst #(
	parameter real TCK_NS = 10.417          // 96 MHz
) (
	input             SDRAM_CLK,
	input      [12:0] SDRAM_A,
	input      [1:0]  SDRAM_BA,
	input      [15:0] DQ_IN,         // controller -> chip (Verilator: no tristates)
	output reg [15:0] DQ_Q,          // chip -> controller
	output reg        DQ_OE,
	input             SDRAM_DQML,
	input             SDRAM_DQMH,
	input             SDRAM_nCS,
	input             SDRAM_nCAS,
	input             SDRAM_nRAS,
	input             SDRAM_nWE,
	input             SDRAM_CKE,
	output reg [31:0] violations = 0
);
	reg [15:0] mem [0:16*1024*1024-1] /*verilator public_flat_rw*/;
	localparam integer tRCD = $rtoi(18.0 / TCK_NS + 0.999), tRP = $rtoi(18.0 / TCK_NS + 0.999),
	                   tRAS = $rtoi(42.0 / TCK_NS + 0.999), tRC = $rtoi(60.0 / TCK_NS + 0.999),
	                   tRRD = $rtoi(12.0 / TCK_NS + 0.999);
	wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
	localparam C_MODE = 3'b000, C_REF = 3'b001, C_PRE = 3'b010, C_ACT = 3'b011, C_WR = 3'b100, C_RD = 3'b101;

	reg [3:0]  bl = 4'd1;
	reg        wsingle = 1'b0;
	reg [2:0]  cl = 3'd2;
	reg [12:0] open_row [0:3];
	reg        is_open [0:3];
	integer    t = 0, t_act [0:3], t_pre [0:3], t_last_act = -100;
	integer    i;
	reg [8:0]  rcol;
	initial for (i = 0; i < 4; i = i + 1) begin is_open[i] = 0; t_act[i] = -100; t_pre[i] = -100; end

	// read pipeline: up to CL + BL words ahead
	reg [15:0] q_data [0:15];
	reg        q_val  [0:15];
	initial for (i = 0; i < 16; i = i + 1) q_val[i] = 0;
	initial DQ_OE = 0;

	// write burst in progress
	reg [3:0]  wr_left = 0;
	reg [1:0]  wr_ba;
	reg [8:0]  wr_col;

	// refresh: REF commands, and the longest stretch between two (clocks).
	// The model keeps its contents without refresh; a real chip needs 8192
	// in every 64 ms (one per 7.8 us), and loses bits some time past that
	integer    ref_n /*verilator public_flat_rw*/ = 0, ref_last = 0, ref_gap_max /*verilator public_flat_rw*/ = 0;
	always @(posedge SDRAM_CLK)
		if (!SDRAM_nCS && SDRAM_CKE && cmd == C_REF) begin
			ref_n <= ref_n + 1;
			if (t - ref_last > ref_gap_max) ref_gap_max <= t - ref_last;
			ref_last <= t;
		end

	task automatic viol(input [255:0] what);
		begin
			violations = violations + 1;
			if (violations <= 8) $display("SDRAM model: %0s at t=%0d (bank %0d)", what, t, SDRAM_BA);
		end
	endtask

	always @(posedge SDRAM_CLK) begin
		t = t + 1;
		DQ_OE <= q_val[0];
		DQ_Q  <= q_data[0];
		for (i = 0; i < 15; i = i + 1) begin q_val[i] = q_val[i + 1]; q_data[i] = q_data[i + 1]; end
		q_val[15] = 0;
		// write burst data
		if (wr_left != 0) begin
			if (!SDRAM_DQML) mem[{wr_ba, open_row[wr_ba], wr_col}][7:0]  = DQ_IN[7:0];
			if (!SDRAM_DQMH) mem[{wr_ba, open_row[wr_ba], wr_col}][15:8] = DQ_IN[15:8];
			wr_col = (wr_col & ~(bl - 1)) | ((wr_col + 1) & (bl - 1));
			wr_left = wr_left - 1;
		end
		if (!SDRAM_nCS && SDRAM_CKE && cmd != 3'b111 && $test$plusargs("cmdlog")) $display("  t=%0d cmd %0d ba %0d a %h", t, cmd, SDRAM_BA, SDRAM_A);
		if (!SDRAM_nCS && SDRAM_CKE) case (cmd)
			C_MODE: begin
				bl = 4'd1 << SDRAM_A[2:0];
				cl = SDRAM_A[6:4];
				wsingle = SDRAM_A[9];
			end
			C_ACT: begin
				if (is_open[SDRAM_BA]) viol("ACTIVATE on an open bank");
				if (t - t_pre[SDRAM_BA] < tRP) viol("tRP");
				if (t - t_act[SDRAM_BA] < tRC) viol("tRC");
				if (t - t_last_act < tRRD) viol("tRRD");
				open_row[SDRAM_BA] = SDRAM_A;
				is_open[SDRAM_BA] = 1;
				t_act[SDRAM_BA] = t;
				t_last_act = t;
			end
			C_PRE: begin
				for (i = 0; i < 4; i = i + 1)
					if ((SDRAM_A[10] || i == SDRAM_BA) && is_open[i]) begin
						if (t - t_act[i] < tRAS) viol("tRAS");
						is_open[i] = 0; t_pre[i] = t;
					end
			end
			C_RD, C_WR: begin
				if (!is_open[SDRAM_BA]) viol("READ/WRITE on a closed bank");
				if (t - t_act[SDRAM_BA] < tRCD) viol("tRCD");
				if (cmd == C_RD) begin
					for (i = 0; i < bl; i = i + 1) begin
						// word i on DQ during clock CL + i after the command (the pipeline
						// is shifted before DQ_Q samples it, hence CL - 2)
						q_val[cl - 2 + i] = 1;
						// the column is sized first: an integer term inside the {}
						// would widen it and push the row and bank out of the index
						rcol = (SDRAM_A[8:0] & ~(bl - 1)) | ((SDRAM_A[8:0] + i[8:0]) & (bl - 1));
						q_data[cl - 2 + i] = mem[{SDRAM_BA, open_row[SDRAM_BA], rcol}];
					end
				end else begin
					wr_ba = SDRAM_BA; wr_col = SDRAM_A[8:0];
					if (!SDRAM_DQML) mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}][7:0]  = DQ_IN[7:0];
					if (!SDRAM_DQMH) mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}][15:8] = DQ_IN[15:8];
					wr_col = (wr_col & ~(bl - 1)) | ((wr_col + 1) & (bl - 1));
					wr_left = wsingle ? 4'd0 : bl - 4'd1;
				end
				if (SDRAM_A[10]) begin is_open[SDRAM_BA] = 0; t_pre[SDRAM_BA] = t + bl; end   // auto precharge
			end
			default: ;
		endcase
	end
endmodule
