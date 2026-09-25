// The C65 I/O MCU (MAME namco65.cpp): the HD63705 (rtl/ns2_hd63705.v, NS2-7)
// at 2.048 MHz (its crystal clock: a clock enable every 24 clocks) and its
// memory map:
//   0000-003f RAM, reads of 01 (MCUB), 02 (MCUC), 03 (port D: the analog
//             inputs over 0x7f, as bits), 07 (MCUH), 10 (A/D control), 11 (A/D data)
//   0040-01bf RAM (internal)      01c0-1fff internal ROM (sys2mcpu.bin)
//   2000 DIP switches            3000-3003 dials
//   5000-57ff DPRAM              6000-6fff watchdog (reads 0)
//   8000-ffff the set's EPROM
// A/D as MAME models it: a control write with bit 6 converts at once
// (channel bits 4-2), sets the complete flag (bit 7 of the control read,
// cleared by a control read then a data read) and, with bit 5, interrupts.
// IRQ1 (line 200) and the A/D interrupt are latched until the core fetches
// their vectors (0x1ff8, 0x1fea), as MAME's pending interrupts. MAME holds
// the IRQ1 input (HOLD_LINE) until the core enters any interrupt, and the
// core latches IRQ1 only when that input changes: a line-200 event while the
// input is still held is lost. The input survives the MCU's reset (only
// power-on clears it), so the first line 200 after the master releases the
// MCU is lost unless an interrupt was taken first.
module ns2_c65 (
	input             clk,
	input             por,            // the board's reset
	input             reset,          // held while the master's C148 keeps the MCU in reset
	input             irq_line200,    // one clock pulse
	// ROMs: data one clock after the address (internal 8 KB, external 32 KB)
	output     [12:0] irom_addr,
	input      [7:0]  irom_data,
	output     [14:0] erom_addr,
	input      [7:0]  erom_data,
	// the DPRAM's MCU port
	output reg [10:0] dp_addr,
	output reg [7:0]  dp_dout,
	output reg        dp_we,
	input      [7:0]  dp_din,
	// inputs (MAME's ports, active low where the board is)
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,          // di0..di3
	input      [63:0] analog,         // an0..an7
	// debug: the core's bus
	output     [15:0] dbg_addr,
	output            dbg_wr,
	output     [7:0]  dbg_dout
);
	// 2.048 MHz
	reg [4:0] div;
	always @(posedge clk) div <= (reset || div == 5'd23) ? 5'd0 : div + 1'd1;
	wire cen = div == 5'd23;

	wire [15:0] a;
	wire        wr;
	wire [7:0]  dout;
	reg  [7:0]  din;
	reg         irq_p, adc_p;
	reg         irq_in;               // MAME's IRQ1 input: held until an interrupt is taken
	wire        rd;
	ns2_hd63705 u_cpu (.rst(reset), .clk(clk), .cen(cen), .irq(irq_p), .adc(adc_p), .wr(wr), .rd(rd), .tstop(),
	                   .addr(a), .din(din), .dout(dout));
	assign dbg_addr = a; assign dbg_wr = wr && cen; assign dbg_dout = dout;
	assign irom_addr = a[12:0];
	assign erom_addr = a[14:0];

	reg [7:0] ram [0:447];            // 0000-01bf
	reg [7:0] ram_q;
	reg [7:0] an_ctrl, an_data;
	reg [1:0] an_done;

	// the analog inputs as bits (port D)
	wire [7:0] pd;
	genvar gi;
	generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_pd
		assign pd[gi] = analog[8 * gi +: 8] > 8'h7f;
	end endgenerate

	wire sel_ram  = a < 16'h01c0;
	wire sel_irom = a < 16'h2000;
	wire sel_erom = a[15];
	wire sel_dp   = a[15:11] == 5'b01010;          // 5000-57ff
	always @(posedge clk) ram_q <= ram[a[8:0]];
	always @(*) begin
		if (a == 16'h0001) din = mcub;
		else if (a == 16'h0002) din = mcuc;
		else if (a == 16'h0003) din = pd;
		else if (a == 16'h0007) din = mcuh;
		else if (a == 16'h0010) din = {an_done != 0, 1'b0, an_ctrl[5:0]};
		else if (a == 16'h0011) din = an_data;
		else if (a == 16'h0000) din = 8'h00;
		else if (sel_ram)  din = ram_q;
		else if (sel_irom) din = irom_data;
		else if (a == 16'h2000) din = dsw;
		else if (a[15:2] == 14'h0c00) din = dials[8 * a[1:0] +: 8];
		else if (sel_dp)   din = dp_din;
		else if (sel_erom) din = erom_data;
		else din = 8'h00;
	end
	always @(posedge clk) begin
		dp_addr <= a[10:0]; dp_dout <= dout;
		dp_we <= cen && wr && sel_dp;
	end

	// the core's reads that change state: the fetch strobe of the microcode
	wire fetch = cen && rd;
	always @(posedge clk) begin
		if (por) irq_in <= 1'b0;
		else if (irq_line200) irq_in <= 1'b1;
		else if (!reset && fetch && (a == 16'h1ff8 || a == 16'h1fea)) irq_in <= 1'b0;
	end
	always @(posedge clk) begin
		if (reset) begin
			irq_p <= 1'b0; adc_p <= 1'b0; an_ctrl <= 0; an_data <= 8'haa; an_done <= 0;
		end else begin
			if (irq_line200 && !irq_in) irq_p <= 1'b1;
			// the vector fetch takes the interrupt
			if (fetch && a == 16'h1ff8) irq_p <= 1'b0;
			if (fetch && a == 16'h1fea) adc_p <= 1'b0;
			if (cen && wr) begin
				if (sel_ram) ram[a[8:0]] <= dout;
				if (a == 16'h0010) begin
					an_ctrl <= dout;
					if (dout[6]) begin
						an_done <= 2'd2;
						an_data <= analog[8 * dout[4:2] +: 8];
						if (dout[5]) adc_p <= 1'b1;
					end
				end
			end
			if (fetch && a == 16'h0010 && an_done == 2'd2) an_done <= 2'd1;
			if (fetch && a == 16'h0011 && an_done == 2'd1) an_done <= 2'd0;
		end
	end
endmodule
