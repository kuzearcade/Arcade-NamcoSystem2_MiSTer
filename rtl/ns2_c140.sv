// C140 (MAME c140.cpp): the register file, the key-on status and the INT1
// timer that drives the 6809's FIRQ. The 24 voices' playback is M2's audio
// step; until then a voice's key flag follows key-on and key-off only (MAME
// also clears it when a non-looping sample ends), which the key-on status
// read reports in bit 6.
//   0x000-0x17f  24 voices x 16 registers; register 5 is the mode, key-on
//                on bit 7 (or bit 6 while keyed)
//   0x1f8        INT1 reload; reads back the written value + 1
//   0x1fa        a write clears INT1 and, when enabled, restarts the timer:
//                INT1 rises (reload + 1) * 2 base-rate ticks later
//   0x1fe        bit 0 enables INT1 (asserted at once when no timer runs);
//                0 clears it and stops the timer
// The base rate is the chip clock, 21.333 kHz (clk / 2304).
module ns2_c140 (
	input             clk,
	input             reset,
	input             cs,             // one clock strobe per access
	input             we,
	input      [8:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	output reg        int1            // to the 6809's FIRQ (active high)
);
	reg [7:0]  regs [0:511];
	reg [23:0] key;                   // per voice
	// the timer counts clocks from the write, as MAME's (an exact duration,
	// not the base-rate ticks' edges): (reload + 1) * 2 * 2304 clocks
	reg [20:0] tcount;
	reg        running;

	wire [4:0] voice = addr[8:4];
	always @(*) begin
		if (addr[3:0] == 4'h5 && addr < 9'h180) dout = {1'b0, key[voice], regs[addr][5:0]};
		else if (addr == 9'h1f8)             dout = regs[addr] + 1'd1;
		else                                 dout = regs[addr];
	end

	always @(posedge clk) begin
		if (reset) begin
			key <= 0; int1 <= 1'b0; running <= 1'b0; tcount <= 0;
		end else begin
			if (running) begin
				if (tcount == 21'd1) begin int1 <= 1'b1; running <= 1'b0; end
				tcount <= tcount - 1'd1;
			end
			if (cs && we) begin
				regs[addr] <= din;
				if (addr < 9'h180 && addr[3:0] == 4'h5) begin
					if (din[7] || (din[6] && key[voice])) key[voice] <= 1'b1;
					else key[voice] <= 1'b0;
				end
				if (addr == 9'h1fa) begin
					int1 <= 1'b0;
					if (regs[9'h1fe][0]) begin running <= 1'b1; tcount <= ({13'd0, regs[9'h1f8]} + 21'd1) * 21'd4608; end
				end
				if (addr == 9'h1fe) begin
					if (din[0]) begin if (!running) int1 <= 1'b1; end
					else begin int1 <= 1'b0; running <= 1'b0; end
				end
			end
		end
	end
endmodule
