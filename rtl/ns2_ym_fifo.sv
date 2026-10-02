// The YM2151's writes through a FIFO (NS2-26), from ns2_sound to jt51.
// jt51 applies an operator or key-on write over the next 32 of its cycles
// (64 with its half-rate phase), and a write before that cancels or
// redirects it; the games
// write every 26-28 cycles without reading the busy flag (Rolling Thunder
// 2: no status read in 20 s, 22,230 writes), and MAME's YM2151 takes
// every write at once. So a write leaves the FIFO at least 64 YM cycles
// after the last data write (an address write after an address write at
// once). With all the sets' logged writes, the queue peaks at 236 (an
// init burst) and a write waits 2 ms at most. The FIFO is a block RAM:
// its head is read a clock after its pointer moves, and a write reaches
// it two clocks after it is made.
module ns2_ym_fifo (
	input            clk,
	input            reset,
	input            ycen,           // the YM2151's clock enable (3.579545 MHz)
	input            we,             // the CPU's write (one clock)
	input            a0,
	input      [7:0] din,
	output reg       wr,             // to jt51 (cs_n low for a clock)
	output reg [8:0] wq              // {a0, data}
);
	(* ramstyle = "M10K" *) reg [8:0] yq [0:511];
	reg  [8:0] yq_w = 9'd0, yq_w1 = 9'd0, yq_w2 = 9'd0, yq_r = 9'd0;
	reg  [8:0] yq_h;                      // yq[yq_r], registered
	reg  [6:0] ygap = 7'd127;             // YM cycles since the last data write left (to 127)
	reg        hold;
	always @(posedge clk) begin
		if (we) yq[yq_w] <= {a0, din};
		yq_h <= yq[yq_r];
	end
	always @(posedge clk) begin
		wr <= 1'b0; hold <= 1'b0;
		if (reset) begin yq_w <= 0; yq_w1 <= 0; yq_w2 <= 0; yq_r <= 0; ygap <= 7'd127; end
		else begin
			if (we) yq_w <= yq_w + 1'd1;
			yq_w1 <= yq_w; yq_w2 <= yq_w1;
			if (ycen && ygap != 7'd127) ygap <= ygap + 1'd1;
			if (yq_r != yq_w2 && !hold && ygap >= 7'd64) begin
				wr <= 1'b1; wq <= yq_h; yq_r <= yq_r + 1'd1; hold <= 1'b1;
				if (yq_h[8]) ygap <= 7'd0;
			end
		end
	end
endmodule
