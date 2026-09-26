// The C68 I/O MCU (MAME namco68.cpp): an M37450 (rtl/ns2_m740.sv, NS2-9) at
// 8.192 MHz, a cycle every 4 clocks: 2.048 MHz, a clock enable every 24
// clocks. Its on-chip peripherals as MAME's m3745x.cpp:
//   0000-00bf RAM            00d6-00dd ports P3-P6 and their direction
//   00e2-00e3 A/D            00fc-00ff interrupt requests and enables
//   0100-01ff RAM (the stack)
// and the board's map (c68_default_am):
//   2000 DIP switches        3000-3003 dials
//   5000-57ff DPRAM          6000-6fff a read acknowledges the VBL interrupt
//   8000-ffff c68.bin, the device's own ROM (every C68 set runs it)
// Ports: P3 reads MCUC with its nibbles swapped, and its bit 7 (written,
// through the direction register) selects the player half P5 reads from
// MCUB and MCUH; P4 and P6 read 0. The A/D converts 50 cycles after a
// control write with bit 3 clear, then sets bit 3 and requests its
// interrupt; a data read clears the request.
// Interrupts: MAME's m3745x maps the enabled requests to m740 lines; any
// raises irq and the lowest line gives the vector (0xfffc - 2 * line):
//   requests 1 bit 2 (INT1, line 200's VBL) -> line 2, 0xfff8
//   requests 1 bits 3, 4 -> lines 3, 4;  requests 2 bits 3, 4, 5 (A/D) -> lines 11-13
// MAME checks for an interrupt at the end of an opcode fetch cycle, and
// sees the events up to that time: line 200 counts at the cycle boundary it
// lands on (irq includes the pulse). A bus access happens at its cycle's
// start, so the A/D, 50 cycles after its control write, completes at the
// end of the write's 49th following cycle.
module ns2_c68 (
	input             clk,
	input             reset,          // held while the master's C148 keeps the MCU in reset
	input             irq_line200,    // one clock pulse
	input             rom_ready,      // the ROM's cache has the byte (1 with the arrays)
	output            rom_rd,         // a ROM read is on the bus
	output            rom_smp,        // rom_rd and the address have settled (ns2_rom_cache SAMPLED)
	// the ROM: c68.bin (32 KB), data one clock after the address
	output     [14:0] rom_addr,
	input      [7:0]  rom_data,
	// the DPRAM's MCU port
	output reg [10:0] dp_addr,
	output reg [7:0]  dp_dout,
	output reg        dp_we,
	input      [7:0]  dp_din,
	// inputs (MAME's ports)
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,          // di0..di3
	input      [63:0] analog,         // an0..an7
	// debug: the core's bus
	output     [15:0] dbg_addr,
	output            dbg_wr,
	output     [7:0]  dbg_dout,
	output            dbg_tap,        // MAME's taps see this access
	output            dbg_sync,       // an opcode fetch
	output            dbg_cen,
	output     [7:0]  dbg_din         // the cycle's read data
);
	// 2.048 MHz
	reg [4:0] div;
	// a ROM read not ready (a cache over the SDRAM) holds the cycle
	wire rom_wait;
	always @(posedge clk) div <= reset ? 5'd0 : div == 5'd23 ? (rom_wait ? 5'd23 : 5'd0) : div + 1'd1;
	wire cen = div == 5'd23 && !rom_wait;
	// the CPU's outputs change on cen (div 23): five clocks later they have
	// settled (the SDC's 4-cycle multicycle paths from the CPU)
	assign rom_smp = div == 5'd4;

	wire [15:0] a;
	wire        wr, sync, tap;
	wire [7:0]  dout;
	reg  [7:0]  din;
	wire        irq;
	reg  [15:0] irq_vector;
	ns2_m740 u_cpu (.clk(clk), .rst(reset), .cen(cen), .irq(irq), .irq_vector(irq_vector),
	                .addr(a), .dout(dout), .wr(wr), .sync(sync), .tap(tap), .din(din));
	assign dbg_addr = a; assign dbg_wr = wr && cen; assign dbg_dout = dout;
	assign dbg_tap = tap; assign dbg_sync = sync; assign dbg_cen = cen; assign dbg_din = din;
	assign rom_addr = a[14:0];

	// ------------------------------------------------ the peripherals
	reg  [7:0] ram [0:511] /*verilator public_flat_rw*/;  // 0000-00bf, 0100-01ff
	reg  [7:0] ram_q;
	reg  [7:0] port [0:3], ddr [0:3]; // P3, P4, P5, P6
	reg        mux;                    // P3 bit 7: the player half
	reg  [7:0] req1, req2, ctl1, ctl2, adctrl;
	reg  [5:0] adc_cnt;
	reg        ev200;

	// the ports' inputs (MAME's read_p callbacks)
	wire [15:0] ph_pb = {mcuh, mcub};
	wire [7:0]  p5_in = mux ? {ph_pb[6], ph_pb[8], ph_pb[10], ph_pb[12], ph_pb[4], ph_pb[2], ph_pb[0], ph_pb[14]}
	                        : {ph_pb[7], ph_pb[9], ph_pb[11], ph_pb[13], ph_pb[5], ph_pb[3], ph_pb[1], ph_pb[15]};
	wire [7:0]  p_in [0:3];
	assign p_in[0] = {mcuc[3:0], mcuc[7:4]};
	assign p_in[1] = 8'h00;
	assign p_in[2] = p5_in;
	assign p_in[3] = 8'h00;
	function [7:0] rport(input [1:0] i);
		rport = (p_in[i] & ~ddr[i]) | (port[i] & ddr[i]);
	endfunction

	// the interrupt lines (m3745x recalc_irqs, m740 set_irq_line)
	wire [15:0] all_ints = {req1 & ctl1, req2 & ctl2};
	wire [5:0]  lines = {all_ints[5:3], all_ints[12:10]};   // lines 13, 12, 11, 4, 3, 2
	assign irq = lines != 0 || (irq_line200 && ctl1[2] && !reset);
	reg  [5:0]  lines_d;

	wire sel_ram  = a < 16'h00c0 || a[15:8] == 8'h01;
	wire sel_dp   = a[15:11] == 5'b01010;              // 5000-57ff
	wire sel_rom  = a[15];
	assign rom_rd = sel_rom && !wr;
	assign rom_wait = rom_rd && !rom_ready;
	always @(posedge clk) ram_q <= ram[{a[8], a[7:0]}];
	always @(*) begin
		if (sel_ram)                     din = ram_q;
		else if (a[15:3] == 13'h001a && a[2:0] >= 3'd6) din = a[0] ? ddr[0] : rport(2'd0);    // d6, d7
		else if (a == 16'h00d8)          din = rport(2'd1);
		else if (a == 16'h00d9)          din = 8'hff;
		else if (a == 16'h00da)          din = rport(2'd2);
		else if (a == 16'h00db)          din = ddr[2];
		else if (a == 16'h00dc)          din = rport(2'd3);
		else if (a == 16'h00dd)          din = ddr[3];
		else if (a == 16'h00e2)          din = analog[8 * adctrl[2:0] +: 8];
		else if (a == 16'h00e3)          din = adctrl;
		else if (a == 16'h00fc)          din = req1;
		else if (a == 16'h00fd)          din = req2;
		else if (a == 16'h00fe)          din = ctl1;
		else if (a == 16'h00ff)          din = ctl2;
		else if (a == 16'h2000)          din = dsw;
		else if (a[15:2] == 14'h0c00)    din = dials[8 * a[1:0] +: 8];
		else if (sel_dp)                 din = dp_din;
		else if (sel_rom)                din = rom_data;
		else                             din = 8'h00;
	end
	always @(posedge clk) begin
		dp_addr <= a[10:0]; dp_dout <= dout;
		dp_we <= cen && wr && sel_dp;
	end

	integer i;
	always @(posedge clk) begin
		if (irq_line200) ev200 <= 1'b1;
		if (reset) begin
			// MAME's reset clears the requests: nothing from before the release
			ev200 <= 1'b0;
			for (i = 0; i < 4; i = i + 1) begin port[i] <= 8'h00; ddr[i] <= 8'h00; end
			mux <= 1'b0; req1 <= 0; req2 <= 0; ctl1 <= 0; ctl2 <= 0; adctrl <= 0; adc_cnt <= 0;
			irq_vector <= 16'hfffc; lines_d <= 0;
		end else if (cen) begin
			// line 200 (INT1), at the cycle boundary it lands on or the next
			if (ev200 || irq_line200) begin req1 <= req1 | 8'h04; ev200 <= 1'b0; end
			// the A/D: 50 cycles from the start of the control write's cycle
			if (adc_cnt == 6'd1) begin adctrl <= adctrl | 8'h08; req2 <= req2 | 8'h20; end
			if (adc_cnt != 0) adc_cnt <= adc_cnt - 1'd1;
			if (wr) begin
				if (sel_ram) ram[{a[8], a[7:0]}] <= dout;
				case (a)
					16'h00d6: begin port[0] <= dout; mux <= (dout & ddr[0]) >> 7; end
					16'h00d7: begin ddr[0] <= dout;  mux <= (port[0] & dout) >> 7; end
					16'h00d8: port[1] <= dout;
					16'h00da: port[2] <= dout;
					16'h00db: ddr[2] <= dout;
					16'h00dc: port[3] <= dout;
					16'h00dd: ddr[3] <= dout;
					16'h00e3: begin adctrl <= dout; if (!dout[3]) adc_cnt <= 6'd48; end
					16'h00fc: req1 <= dout;
					16'h00fd: req2 <= dout;
					16'h00fe: ctl1 <= dout;
					16'h00ff: ctl2 <= dout;
					default: ;
				endcase
			end else begin
				// reads with side effects
				if (a == 16'h00e2) req2 <= req2 & ~8'h20;
				if (a[15:12] == 4'h6) req1 <= req1 & ~8'h04;
			end
		end
		// m740 set_irq_line: the vector follows the lowest pending line, and
		// stays when none is left
		if (!reset) begin
			lines_d <= lines;
			if (lines != lines_d && lines != 0)
				irq_vector <= lines[0] ? 16'hfff8 : lines[1] ? 16'hfff6 : lines[2] ? 16'hfff4 :
				              lines[3] ? 16'hffe6 : lines[4] ? 16'hffe4 : 16'hffe2;
		end
	end
endmodule
