// One SDRAM bank's clients (M3): round-robin among N requesters, each a
// stream as the video's (req held until ack; data back in request order
// with valid). Requests go into ns2_sdram's FIFO for the bank; a tag FIFO
// remembers whose each one is, and a returning burst (the bank's valid_t
// toggle) goes to the client at its head. Up to 8 bursts in flight.
module ns2_bank_arb #(parameter N = 2) (
	input                 clk,
	input                 rst,
	input      [N-1:0]    req,
	input      [N*22-1:0] addr,           // 16-bit word addresses in the bank
	output reg [N-1:0]    ack,            // a one-clock pulse: the request is queued
	output reg [N-1:0]    valid,          // a one-clock pulse with data
	output reg [63:0]     data,
	// ns2_sdram's bank
	output reg            push,
	output reg [21:0]     paddr,
	input                 full,
	input                 vtog,
	input      [63:0]     vdata
);
	localparam TW = N <= 2 ? 1 : $clog2(N);
	reg [TW-1:0] tag [0:7];
	reg [3:0]    tw, tr;                      // tag FIFO pointers
	wire         tfull = (tw ^ tr) == 4'b1000;
	reg [TW-1:0] rr;                          // the client after the last one served
	reg          vseen;

	// the next client: the first requester from rr on, not acked last clock
	// (the lowest at or above rr, else the lowest)
	wire [N-1:0] cand = req & ~ack;
	reg          sel_ok;
	reg [TW-1:0] sel;
	reg          hi_ok;
	reg [TW-1:0] hi, lo;
	integer k;
	always @(*) begin
		hi_ok = 1'b0; hi = 0; lo = 0;
		for (k = N - 1; k >= 0; k = k - 1) begin
			if (cand[k]) lo = k;
			if (cand[k] && k >= rr) begin hi_ok = 1'b1; hi = k; end
		end
		sel_ok = |cand;
		sel = hi_ok ? hi : lo;
	end

	always @(posedge clk) begin
		ack <= 0; valid <= 0; push <= 1'b0;
		if (rst) begin tw <= 0; tr <= 0; rr <= 0; vseen <= 1'b0; end
		else begin
			// a request: into the bank's FIFO, its tag into ours
			if (sel_ok && !full && !tfull && !push) begin
				push <= 1'b1; paddr <= addr[22 * sel +: 22];
				tag[tw[2:0]] <= sel; tw <= tw + 1'd1;
				ack[sel] <= 1'b1;
				rr <= sel == N - 1 ? 0 : sel + 1'd1;
			end
			// a burst back: to the client at the tag FIFO's head
			if (vtog != vseen) begin
				vseen <= vtog;
				valid[tag[tr[2:0]]] <= 1'b1; data <= vdata;
				tr <= tr + 1'd1;
			end
		end
	end
endmodule
