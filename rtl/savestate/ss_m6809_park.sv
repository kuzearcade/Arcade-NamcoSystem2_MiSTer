// Savestate support: park a running mc6809is at an instruction boundary
// without touching the vendored CPU, and get its registers out
// (docs/PLAN.md 2.9; the 6809 counterpart of ss_m68k_park / ss_z80_park).
//
// Mechanism:
//   1. park_req pulls NMI low. The 6809 finishes its instruction, stacks the
//      ENTIRE machine state on S (NMI sets E: CC, A, B, DP, X, Y, U, PC -- 12
//      bytes, into the sound-RAM image) and fetches the NMI vector at
//      0xFFFC/0xFFFD. That fetch is substituted with MON_BASE.
//   2. The monitor, served from a bus overlay in an unmapped window
//      (MON_BASE .. +0xFF), stores S in the state register (+0x80/+0x81),
//      writes DONE (+0x82) and spins on RESUME (+0x83).
//   3. On RESUME it reloads S from the state register (restored on a load)
//      and RTIs: every other register comes back off the stack.
//
// The game's own NMI (the sound latch) must not be taken by the monitor:
//   - the park is requested only after the main CPU has parked (no new
//     command can arrive: the core gates park_req with that);
//   - it waits until the game's NMI line has been high for two E cycles
//     and no game NMI is outstanding (edge seen but vector not yet fetched),
//     so the park's NMI edge is always its own.
// The vector is substituted only between the park's NMI edge and its fetch.
//
// Bus cycles are sampled on falling E (`fallE`), where mc6809is samples its
// data input, so the overlay enable changes only between cycles.
module ss_m6809_park #(
	parameter [15:8] MON_BASE = 8'h38      // 0x3800: unmapped on this board
) (
	input             clk,
	input             reset,
	input             fallE,        // the 6809's falling-E enable (ungated by the freeze)

	input             park_req,     // level
	output reg        parked,       // the monitor has written DONE
	input             resume,       // level

	// 6809 bus
	input      [15:0] a,
	input             rnw,
	input             bs, ba,       // BS=1 BA=0: a vector fetch
	input      [7:0]  dout,         // CPU -> bus
	input             game_nmi_n,   // the board's own NMI line

	output            nmi_park_n,   // AND into the CPU's nNMI
	output            sel_mon,      // this read is the overlay's
	output reg [7:0]  mon_data,
	output            at_head,      // this falling E fetches the spin loop's first opcode

	// state register S on the word bus
	input             ss_wr,
	input      [15:0] ss_wdata,
	output     [15:0] ss_rdata
);
	wire vec_fetch = rnw & bs & ~ba;
	wire nmi_vec   = vec_fetch & (a[15:1] == 15'h7FFE);   // FFFC/FFFD

	reg nmi_lo = 1'b0;   // our NMI line is low
	reg arm = 1'b0;      // substitute the next NMI vector fetch
	reg in_mon = 1'b0;   // the CPU is inside the monitor (overlay on)
	reg left = 1'b0;     // the RTI has been fetched

	// the game's NMI: outstanding from its falling edge to its vector fetch
	reg game_d = 1'b1, game_out = 1'b0;
	reg [1:0] quiet = 2'd0;          // E cycles the game's NMI line has been high
	always @(posedge clk) begin
		if (reset) begin game_d <= 1'b1; game_out <= 1'b0; quiet <= 2'd0; end
		else if (fallE) begin
			game_d <= game_nmi_n;
			if (game_d & ~game_nmi_n) game_out <= 1'b1;
			else if (nmi_vec & ~arm) game_out <= 1'b0;
			if (~game_nmi_n) quiet <= 2'd0; else if (quiet != 2'd3) quiet <= quiet + 2'd1;
		end
	end

	// park NMI: raised once the coast is clear, held until the vector fetch
	always @(posedge clk) begin
		if (reset | ~park_req) begin
			nmi_lo <= 1'b0; arm <= 1'b0; in_mon <= 1'b0; left <= 1'b0; parked <= 1'b0;
		end else if (fallE) begin
			if (~nmi_lo & ~arm & ~in_mon & ~left & (quiet == 2'd3) & ~game_out) begin nmi_lo <= 1'b1; arm <= 1'b1; end
			if (arm & nmi_vec & a[0]) begin arm <= 1'b0; nmi_lo <= 1'b0; in_mon <= 1'b1; end   // second vector byte: in
			if (in_mon & ~rnw & (a == {MON_BASE, 8'h82})) parked <= 1'b1;
			if (in_mon & resume & rnw & (a == {MON_BASE, 8'h12})) begin in_mon <= 1'b0; left <= 1'b1; parked <= 1'b0; end
		end
	end
	assign nmi_park_n = ~nmi_lo;

	// state register S
	reg [15:0] sreg = 16'd0;
	always @(posedge clk) begin
		if (ss_wr) sreg <= ss_wdata;
		else if (fallE & in_mon & ~rnw & (a[15:1] == {MON_BASE, 7'h40})) begin
			if (a[0]) sreg[7:0] <= dout; else sreg[15:8] <= dout;
		end
	end
	assign ss_rdata = sreg;

	// the overlay: the vector while armed, the monitor window while inside
	//   00: STS  $xx80     10 FF xx 80
	//   04: LDA  #1        86 01
	//   06: STA  $xx82     B7 xx 82
	//   09: LDA  $xx83     B6 xx 83     (loop)
	//   0C: BEQ  loop      27 FB
	//   0E: LDS  $xx80     10 FE xx 80
	//   12: RTI            3B
	wire in_win = (a[15:8] == MON_BASE);
	assign at_head = fallE & in_mon & rnw & (a == {MON_BASE, 8'h09});
	assign sel_mon = rnw & ((arm & nmi_vec) | (in_mon & in_win));
	always @(*) begin
		if (arm & nmi_vec) mon_data = a[0] ? 8'h00 : MON_BASE;
		else case (a[7:0])
			8'h00: mon_data = 8'h10; 8'h01: mon_data = 8'hFF; 8'h02: mon_data = MON_BASE; 8'h03: mon_data = 8'h80;
			8'h04: mon_data = 8'h86; 8'h05: mon_data = 8'h01;
			8'h06: mon_data = 8'hB7; 8'h07: mon_data = MON_BASE; 8'h08: mon_data = 8'h82;
			8'h09: mon_data = 8'hB6; 8'h0A: mon_data = MON_BASE; 8'h0B: mon_data = 8'h83;
			8'h0C: mon_data = 8'h27; 8'h0D: mon_data = 8'hFB;
			8'h0E: mon_data = 8'h10; 8'h0F: mon_data = 8'hFE; 8'h10: mon_data = MON_BASE; 8'h11: mon_data = 8'h80;
			8'h12: mon_data = 8'h3B;
			8'h80: mon_data = sreg[15:8];
			8'h81: mon_data = sreg[7:0];
			8'h82: mon_data = {7'd0, parked};
			8'h83: mon_data = {7'd0, resume};
			default: mon_data = 8'h12;   // NOP
		endcase
	end
endmodule
