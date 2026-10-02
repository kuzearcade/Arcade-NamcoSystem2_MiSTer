// ns2_ym_fifo and jt51 as ns2_sound wires them, for tb.cpp
module top (
	input         clk,
	input         reset,
	input         we,
	input         a0,
	input  [7:0]  din,
	output        sample,
	output signed [15:0] xleft,
	output signed [15:0] xright
);
	// 3.579545 MHz for the YM2151 (the fraction of 49.152 MHz), as ns2_sound
	reg [26:0] yacc = 0;
	reg        ycen = 0, ycen_p1_t = 0, ycen_p1 = 0;
	always @(posedge clk) begin
		ycen <= 1'b0; ycen_p1 <= 1'b0;
		if (yacc + 27'd3579545 >= 27'd49152000) begin
			yacc <= yacc + 27'd3579545 - 27'd49152000; ycen <= 1'b1;
			ycen_p1_t <= !ycen_p1_t; ycen_p1 <= ycen_p1_t;
		end else yacc <= yacc + 27'd3579545;
	end
	wire       wr;
	wire [8:0] wq;
	ns2_ym_fifo fifo (.clk(clk), .reset(reset), .ycen(ycen), .we(we), .a0(a0), .din(din), .wr(wr), .wq(wq));
	jt51 ym (.rst(reset), .clk(clk), .cen(ycen), .cen_p1(ycen_p1), .cs_n(!wr), .wr_n(1'b0), .a0(wq[8]), .din(wq[7:0]),
		.dout(), .ct1(), .ct2(), .irq_n(), .sample(sample), .left(), .right(), .xleft(xleft), .xright(xright));
endmodule
