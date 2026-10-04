// A small read cache over one SDRAM client (M3), for a CPU's ROM (after
// MS1BCD's rom_cache_n): LINES bursts of four 16-bit words, fully
// associative, FIFO replacement, and a prefetch of the burst after the one
// being read. The consumer reads 16-bit words; `ready` is high while `data`
// is the word at `addr`. A miss costs the CPU wait states.
// A fill never replaces the line being read: a fill landing on it between
// the CPU's DTACK and its data latch would hand it the wrong word.
// The memory side is ns2_mem's client stream: req held until ack, the burst
// back with valid.
module ns2_rom_cache #(
	parameter AW = 17,                // the ROM's size in 16-bit words: 2^AW
	parameter LINES = 16,
	parameter PREFETCH = 1,
	// a slow CPU's cache takes addr and rd while smp, from a phase of its
	// cycle after its registers' outputs settle (the SDC's multicycle paths
	// from the CPU) to the cycle's end, and is ready only while what it took
	// is still the CPU's address: a CPU's address can also follow its data
	// input combinationally (mc6809is drives ADDR = addr_nxt)
	parameter SAMPLED = 0
) (
	input               clk,
	input               rst,
	input               smp,          // SAMPLED: take addr_in and rd_in
	input      [AW-1:0] addr_in,      // a 16-bit word
	input               rd_in,        // the consumer is reading (addr valid)
	output     [15:0]   data,
	output              ready,
	// ns2_mem
	output reg          m_req,
	output reg [AW-3:0] m_addr,       // a burst
	input               m_ack,
	input               m_valid,
	input      [63:0]   m_data
);
	localparam IW = LINES <= 1 ? 1 : $clog2(LINES);
	// the tags in flops (every one compared at once); the lines in an MLAB,
	// read without a register (one write port, the fill; one read, the hit's)
	reg [AW-3:0] tag  [0:LINES-1];
	(* ramstyle = "MLAB, no_rw_check" *) reg [63:0] line [0:LINES-1];
	reg [LINES-1:0] vld;
	reg [IW-1:0] wr_ptr;
	reg          busy;                // a fill in flight (requested, not back)
	reg [AW-1:0] addr_s;
	reg          rd_s;
	always @(posedge clk) if (smp) begin addr_s <= addr_in; rd_s <= rd_in; end
	wire [AW-1:0] addr = SAMPLED ? addr_s : addr_in;
	wire          rd   = SAMPLED ? rd_s && !(rst) : rd_in;
	reg [AW-3:0] fill;                // its burst

	wire [AW-3:0] want = addr[AW-1:2];
	wire [AW-3:0] next = want + 1'd1;

	// the hit
	reg          hit, nhit;
	reg [IW-1:0] hi;
	integer k;
	always @(*) begin
		hit = 1'b0; nhit = 1'b0; hi = 0;
		for (k = 0; k < LINES; k = k + 1) begin
			if (vld[k] && tag[k] == want) begin hit = 1'b1; hi = k; end
			if (vld[k] && tag[k] == next) nhit = 1'b1;
		end
	end
	wire [63:0] hl = line[hi];
	assign data  = hl[16 * addr[1:0] +: 16];
	assign ready = hit && (!SAMPLED || (rd_s && addr_s == addr_in));

	// statistics (simulation only: sim/rtl/ns2_hw reads them): reads, misses,
	// the clocks a read waited
`ifdef VERILATOR
	reg [31:0] n_reads /*verilator public_flat_rd*/, n_miss /*verilator public_flat_rd*/, n_wait /*verilator public_flat_rd*/;
	reg        rd_d;
	reg [AW-1:0] addr_d;
	always @(posedge clk) begin
		rd_d <= rd; addr_d <= addr;
		if (rst) begin n_reads <= 0; n_miss <= 0; n_wait <= 0; end
		else begin
			if (rd && (!rd_d || addr != addr_d)) begin n_reads <= n_reads + 1'd1; if (!hit) n_miss <= n_miss + 1'd1; end
			if (rd && !hit) n_wait <= n_wait + 1'd1;
		end
	end
`endif

	// the victim: the FIFO slot, unless it holds the line being read
	wire [IW-1:0] victim = (hit && hi == wr_ptr) ? wr_ptr + 1'd1 : wr_ptr;

	always @(posedge clk) begin
		if (rst) begin vld <= 0; wr_ptr <= 0; busy <= 1'b0; m_req <= 1'b0; end
		else begin
			if (m_req && m_ack) m_req <= 1'b0;
			if (!busy) begin
				// a miss first, then the prefetch of the next burst
				if (rd && !hit) begin
					busy <= 1'b1; m_req <= 1'b1; m_addr <= want; fill <= want;
				end else if (PREFETCH && rd && hit && !nhit && next != 0) begin
					busy <= 1'b1; m_req <= 1'b1; m_addr <= next; fill <= next;
				end
			end
			if (busy && m_valid) begin
				busy <= 1'b0;
				tag[victim] <= fill; vld[victim] <= 1'b1;
				wr_ptr <= victim + 1'd1;
			end
		end
	end
	always @(posedge clk) if (!rst && busy && m_valid) line[victim] <= m_data;
endmodule
