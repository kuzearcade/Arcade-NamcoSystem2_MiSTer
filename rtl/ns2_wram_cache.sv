// A 68000's 64 KB work RAM in the SDRAM (the NB bitstream, docs/PLAN.md
// Appendix F): a direct-mapped cache of 2^LW lines of four words in block
// RAM, written through. The CPU side keeps the internal RAM's timing: the
// tag and the word at `addr` are read every clock, so a hit is ready as the
// RAM's word was; a miss (ready low) holds the CPU while one burst fills
// the line. A write updates its line if present and goes to the SDRAM
// through a small FIFO; `wfull` holds the next write cycle when the FIFO is
// full. A fill waits for the FIFO to drain: the bank serves one client's
// requests in order, so a fill always reads the writes before it.
// The memory side is ns2_mem's client stream (req held until ack; a read's
// burst back with valid; a write has no reply).
module ns2_wram_cache #(parameter LW = 8) (
	input             clk,
	input             rst,
	input             flush,          // empty every line (the savestate's, at its transfer's end)
	input      [14:0] addr,           // the CPU's word in the 64 KB
	input             rd,             // a read of the work RAM is on the bus
	input             wr,             // a write: one clock, with its data and strobes
	input      [15:0] wdata,
	input      [1:0]  wbe,            // {upper, lower} byte strobes
	output     [15:0] q,              // the word at addr, when ready
	output            ready,
	output            wfull,
	// ns2_mem
	output reg        m_req,
	output reg        m_we,
	output reg [14:0] m_addr,         // a write's word, a fill's first word
	output reg [15:0] m_din,
	output reg [1:0]  m_dsn,          // active low
	input             m_ack,
	input             m_valid,
	input      [63:0] m_data
);
	localparam TW = 13 - LW;          // the tag: the word address above the line
	// the lines: words in two byte lanes, tags with their valid bit
	reg [7:0]  d_h [0:(4 << LW) - 1], d_l [0:(4 << LW) - 1];
	reg [TW:0] tag [0:(1 << LW) - 1];
	reg [7:0]  q_h, q_l;
	reg [TW:0] t_q;
	reg [14:0] a_q;                   // the address the reads were for
	reg        v_q;                   // and they were the CPU's (no fill, no clear)

	// the port's user: a fill's word, a line clear (reset), a CPU write, the CPU's read
	reg        filling, clearing;
	reg [1:0]  f_w;                   // the fill's word
	reg [63:0] f_data;
	reg [14:0] f_addr;
	reg [LW-1:0] c_line;
	wire [LW+1:0] d_a = filling ? {f_addr[LW+1:2], f_w} : addr[LW+1:0];
	wire [LW-1:0] t_a = clearing ? c_line : filling ? f_addr[LW+1:2] : addr[LW+1:2];

	wire        tag_ok = t_q[TW] && t_q[TW-1:0] == a_q[14:LW+2];
	wire        cur = v_q && a_q == addr;         // the reads are for this address
	wire        hit = cur && tag_ok;
	wire        miss = rd && cur && !tag_ok;
	assign q = {q_h, q_l};
	assign ready = hit && !filling;
	wire        w_hit = wr && hit;    // a write to a line present: update it

	wire [15:0] f_word = f_data[16 * f_w +: 16];
	always @(posedge clk) begin
		if (filling) begin d_h[d_a] <= f_word[15:8]; d_l[d_a] <= f_word[7:0]; end
		else if (w_hit) begin
			if (wbe[1]) d_h[d_a] <= wdata[15:8];
			if (wbe[0]) d_l[d_a] <= wdata[7:0];
		end
		q_h <= d_h[d_a]; q_l <= d_l[d_a];
	end
	always @(posedge clk) begin
		if (clearing) tag[t_a] <= 0;
		else if (filling && f_w == 2'd3) tag[t_a] <= {1'b1, f_addr[14:LW+2]};
		t_q <= tag[t_a];
		a_q <= addr; v_q <= !filling && !clearing;
	end

	// the write FIFO
	reg [14:0] wq_a [0:3];
	reg [15:0] wq_d [0:3];
	reg [1:0]  wq_b [0:3];
	reg [2:0]  wq_w, wq_r;
	wire [2:0] wq_n = wq_w - wq_r;
	assign wfull = wq_n == 3'd4;

	reg        m_busy;                // a fill requested, its burst not back
	always @(posedge clk) begin
		if (rst) begin
			wq_w <= 0; wq_r <= 0; m_req <= 1'b0; m_busy <= 1'b0; filling <= 1'b0;
			clearing <= 1'b1; c_line <= 0;
		end else begin
			if (clearing) begin c_line <= c_line + 1'd1; if (&c_line) clearing <= 1'b0; end
			if (flush) begin clearing <= 1'b1; c_line <= 0; end
			if (wr && !wfull) begin
				wq_a[wq_w[1:0]] <= addr; wq_d[wq_w[1:0]] <= wdata; wq_b[wq_w[1:0]] <= wbe;
				wq_w <= wq_w + 1'd1;
			end
			if (m_req && m_ack) begin
				m_req <= 1'b0;
				if (m_we) wq_r <= wq_r + 1'd1;
			end
			if (!m_req && !m_busy && !filling && !clearing) begin
				// the FIFO's writes first, then a read's miss
				if (wq_n != 0) begin
					m_req <= 1'b1; m_we <= 1'b1;
					m_addr <= wq_a[wq_r[1:0]]; m_din <= wq_d[wq_r[1:0]]; m_dsn <= ~wq_b[wq_r[1:0]];
				end else if (miss) begin
					m_req <= 1'b1; m_we <= 1'b0; m_addr <= {addr[14:2], 2'b00}; m_dsn <= 2'b11;
					m_busy <= 1'b1; f_addr <= addr;
				end
			end
			if (m_busy && m_valid) begin m_busy <= 1'b0; filling <= 1'b1; f_w <= 0; f_data <= m_data; end
			if (filling) begin f_w <= f_w + 1'd1; if (f_w == 2'd3) filling <= 1'b0; end
		end
	end
endmodule
