// The key custom (namcos2_m.cpp namcos2_68k_key_r / _w): 8 word registers.
// Per set, some offsets return a constant (the protection check); every
// other read returns MAME's random value, which the oracle patch makes the
// LFSR r = (r >> 1) ^ (r & 1 ? 0xb400 : 0), seeded 0xace1 at reset (D5).
// Two sets hand-shake:
//   mode 1 (Marvel Land): writing 0x615e to offset 5 arms, 0x1001 to offset 6
//     disarms; offset 7 then reads 0xbe (armed) or 1
//   mode 2 (Rolling Thunder 2): writing 0x13ec to offset 4 or 7 arms; the next
//     read of offset 4 or 7 returns 0x13f and disarms (otherwise the LFSR)
// The table: {valid, value} per offset, from tools/ns2_keys.py.
module ns2_key (
	input             clk,
	input             reset,
	input      [135:0] table_in,     // offset k at [17k +: 17]: {valid, value[15:0]}
	input      [1:0]  mode,
	input             cs,
	input             rd,            // one clock strobe per access
	input             we,
	input      [2:0]  offset,
	input      [15:0] din,
	output reg [15:0] dout
);
	reg [15:0] rng;
	reg        armed;
	wire [16:0] ent = table_in[17 * offset +: 17];
	wire [15:0] next_rng = {1'b0, rng[15:1]} ^ (rng[0] ? 16'hb400 : 16'h0000);

	always @(*) begin
		if (mode == 2'd1 && offset == 3'd7)      dout = armed ? 16'h00be : 16'h0001;
		else if (mode == 2'd2 && (offset == 3'd4 || offset == 3'd7) && armed) dout = 16'h013f;
		else if (ent[16])                        dout = ent[15:0];
		else                                     dout = next_rng;
	end

	always @(posedge clk) begin
		if (reset) begin rng <= 16'hace1; armed <= 1'b0; end
		else begin
			if (cs && rd) begin
				// a read that returned the random value steps the LFSR
				if (!(mode == 2'd1 && offset == 3'd7) &&
				    !(mode == 2'd2 && (offset == 3'd4 || offset == 3'd7) && armed) && !ent[16])
					rng <= next_rng;
				if (mode == 2'd2 && (offset == 3'd4 || offset == 3'd7) && armed) armed <= 1'b0;
			end
			if (cs && we) begin
				if (mode == 2'd1 && offset == 3'd5 && din == 16'h615e) armed <= 1'b1;
				if (mode == 2'd1 && offset == 3'd6 && din == 16'h1001) armed <= 1'b0;
				if (mode == 2'd2 && (offset == 3'd4 || offset == 3'd7) && din == 16'h13ec) armed <= 1'b1;
			end
		end
	end
endmodule
