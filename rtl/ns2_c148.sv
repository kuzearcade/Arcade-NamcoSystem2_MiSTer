// C148: a 68000's interrupt controller and board control (namco_c148.cpp).
// One per 68000; the pair is linked (a write to 0x10000 interrupts the other).
//
// The CPU sees it at 0x1c0000-0x1fffff; the byte (low lane) registers by
// offset bits 17-13:
//   0x04000 bus control (3 bits)      0x06000 CPU IRQ level   0x08000 EX IRQ level
//   0x0a000 POS IRQ level             0x0c000 SCI IRQ level   0x0e000 VBLANK IRQ level
//   0x10000 (w) interrupt the other CPU
//   0x16000..0x1e000 (r or w) ack: CPU, EX, POS, SCI, VBLANK
//   0x20000 (r) ext: the EEPROM's ready bit   0x22000 (w) ext1: sound CPU reset
//   0x24000 (w) ext2: slave and MCU reset     0x26000 watchdog
//
// MAME drives the 68000's input line of the source's level, not a per-source
// OR: a trigger sets the line of the source's current level, an ack (or a
// level write, which acks first) clears it, whatever else shares the level.
// VBLANK is HOLD_LINE: the CPU's interrupt acknowledge of that level clears
// it; the others stay asserted until acked. The IPL is the highest line set.
module ns2_c148 (
	input             clk,
	input             reset,
	// the CPU's accesses to 0x1c0000-0x1fffff (one clock strobe each)
	input             cs,
	input             we,
	input             rd,            // a read (the ack registers ack on reads too)
	input      [17:1] addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	// events
	input             vblank,        // line 240
	input             posirq,        // the C116 line
	input             cpuirq_in,     // the other C148's 0x10000 write
	output reg        cpuirq_out,
	input             iack,          // the CPU acknowledges level iack_lvl
	input      [2:0]  iack_lvl,
	output     [2:0]  ipl,           // active high (the 68000's IPL is its inverse)
	// control
	input      [2:0]  ext_in,        // bit 0: the EEPROM is ready
	output reg [2:0]  ext1,          // bit 0: the sound CPU runs
	output reg [2:0]  ext2,          // bit 0: the slave and the MCU run
	output reg [2:0]  bus_ctrl
);
	reg [2:0] lv_cpu, lv_ex, lv_pos, lv_sci, lv_vbl;
	reg [7:1] line;                  // asserted
	reg [7:1] hold;                  // asserted by HOLD_LINE (cleared by the acknowledge)

	wire [4:0] r = addr[17:13];
	always @(*) begin
		case (r)
			5'h02: dout = {5'd0, bus_ctrl};
			5'h03: dout = {5'd0, lv_cpu};
			5'h04: dout = {5'd0, lv_ex};
			5'h05: dout = {5'd0, lv_pos};
			5'h06: dout = {5'd0, lv_sci};
			5'h07: dout = {5'd0, lv_vbl};
			5'h10: dout = {5'd0, ext_in};
			default: dout = 8'h00;
		endcase
	end

	assign ipl = line[7] ? 3'd7 : line[6] ? 3'd6 : line[5] ? 3'd5 : line[4] ? 3'd4 :
	             line[3] ? 3'd3 : line[2] ? 3'd2 : line[1] ? 3'd1 : 3'd0;

	// set or clear the line of a level (level 0 is no interrupt)
	task automatic setl(input [2:0] l, input h);
		if (l != 0) begin line[l] = 1'b1; hold[l] = h; end
	endtask
	task automatic clrl(input [2:0] l);
		if (l != 0) begin line[l] = 1'b0; hold[l] = 1'b0; end
	endtask

	always @(posedge clk) begin
		cpuirq_out <= 1'b0;
		if (reset) begin
			lv_cpu <= 0; lv_ex <= 0; lv_pos <= 0; lv_sci <= 0; lv_vbl <= 0;
			line = 0; hold = 0; bus_ctrl <= 0; ext1 <= 0; ext2 <= 0;
		end else begin
			// line and hold are updated in order (blocking): the events of one
			// clock apply as MAME applies them, one after another
			// the acknowledge of a held level
			if (iack && iack_lvl != 0 && hold[iack_lvl]) begin line[iack_lvl] = 1'b0; hold[iack_lvl] = 1'b0; end
			// triggers
			if (vblank)    setl(lv_vbl, 1'b1);
			if (posirq)    setl(lv_pos, 1'b0);
			if (cpuirq_in) setl(lv_cpu, 1'b0);
			// the CPU's accesses
			if (cs && we) case (r)
				5'h02: bus_ctrl <= din[2:0];
				5'h03: begin clrl(lv_cpu); lv_cpu <= din[2:0]; end
				5'h04: begin clrl(lv_ex);  lv_ex  <= din[2:0]; end
				5'h05: begin clrl(lv_pos); lv_pos <= din[2:0]; end
				5'h06: begin clrl(lv_sci); lv_sci <= din[2:0]; end
				5'h07: begin clrl(lv_vbl); lv_vbl <= din[2:0]; end
				5'h08: cpuirq_out <= 1'b1;
				5'h0b: clrl(lv_cpu);
				5'h0c: clrl(lv_ex);
				5'h0d: clrl(lv_pos);
				5'h0e: clrl(lv_sci);
				5'h0f: clrl(lv_vbl);
				5'h11: ext1 <= din[2:0];
				5'h12: ext2 <= din[2:0];
				default: ;
			endcase
			if (cs && rd) case (r)
				5'h0b: clrl(lv_cpu);
				5'h0c: clrl(lv_ex);
				5'h0d: clrl(lv_pos);
				5'h0e: clrl(lv_sci);
				5'h0f: clrl(lv_vbl);
				default: ;
			endcase
		end
	end
endmodule
