// One of the two 68000s with its own bus (namcos2.cpp master_common_am /
// slave_common_am): fx68k at 12.288 MHz (a PHI1 and a PHI2 enable every 4
// clocks of the 49.152 MHz clk), its program ROM, 64 KB of work RAM (the
// slave's 0x100000-0x13ffff window mirrors it, NS2-4), the EEPROM (master
// only), its C148; every other address goes to the shared bus, one access
// at a time (the grant), completed long before the 68000 samples DTACK, so
// neither CPU waits, as in MAME (Q8 measures the board's real contention).
// Interrupt acknowledges are answered with the autovector 24 + level (MAME's
// m68000 with the C148 on the IPL lines).
module ns2_cpu #(parameter MASTER = 1) (
	input             clk,
	input             reset,         // the board's reset
	input             run,           // 0 holds the CPU in reset (the slave: the master's C148 ext2)
	input             en_phi1,
	input             en_phi2,
	// program ROM (256 KB): data one clock after the address, or when
	// rom_ready (a cache over the SDRAM: a miss holds DTACK, a wait state)
	output     [17:1] rom_addr,
	input      [15:0] rom_data,
	input             rom_ready,
	output            rom_rd,         // a program ROM read is on the bus
	// the EEPROM's load (the download's default NVRAM, master only)
	input             nv_we,
	input      [12:0] nv_addr,
	input      [7:0]  nv_data,
	// the C148's events
	input             vblank,
	input             posirq,
	input             cpuirq_in,
	output            cpuirq_out,
	output     [2:0]  ext1,          // master: bit 0 = the sound CPU runs
	output     [2:0]  ext2,          // master: bit 0 = the slave and the MCU run
	// the shared bus
	output reg        sh_req,
	output reg [23:1] sh_addr,
	output reg        sh_we,
	output reg        sh_uds,
	output reg        sh_lds,
	output reg [15:0] sh_dout,
	input             sh_done,       // the access is complete (sh_din valid for a read)
	input      [15:0] sh_din,
	// debug: the bus cycle
	output            dbg_as,
	output     [23:1] dbg_addr,
	output            dbg_rnw,
	output     [15:0] dbg_wdata,
	output     [1:0]  dbg_ds,
	output            dbg_iack,
	output     [15:0] dbg_rdata,      // the data the CPU reads (valid with dbg_dtack)
	output            dbg_dtack
);
	wire        eRWn, ASn, LDSn, UDSn, FC0, FC1, FC2;
	wire [15:0] oEdb;
	wire [23:1] eab;
	reg  [15:0] iEdb;
	reg         dtack;
	wire [2:0]  ipl;
	wire        cpu_reset = reset || !run;

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(cpu_reset), .pwrUp(reset),
		.enPhi1(en_phi1), .enPhi2(en_phi2),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(!dtack), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(!ipl[0]), .IPL1n(!ipl[1]), .IPL2n(!ipl[2]),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab));

	wire [23:0] a     = {eab, 1'b0};
	wire        as    = !ASn && (!UDSn || !LDSn);
	wire        iack  = !ASn && FC0 && FC1 && FC2;
	wire        rd    = as && eRWn && !iack;
	wire        wr    = as && !eRWn && !iack;
	assign dbg_as = as && !iack; assign dbg_addr = eab; assign dbg_rnw = eRWn;
	assign dbg_wdata = oEdb; assign dbg_ds = {!UDSn, !LDSn}; assign dbg_iack = iack;
	assign dbg_rdata = iEdb; assign dbg_dtack = dtack;

	// local devices
	wire sel_rom  = a[23:18] == 6'h00;                          // 000000-03ffff
	wire sel_ram  = a[23:18] == 6'h04;                          // 100000-13ffff (64 KB, mirrored)
	wire sel_eep  = MASTER && a[23:14] == 10'h060;              // 180000-183fff
	wire sel_c148 = a[23:18] == 6'h07;                          // 1c0000-1fffff
	wire sel_loc  = sel_rom || sel_ram || sel_eep || sel_c148;

	// the bus cycle: an access starts when AS and a data strobe are low (a
	// write's strobes fall a state after AS, with its data). DTACK for a
	// local device or any write counts from AS alone, or every write would
	// wait a clock: a shared write completes after DTACK (its request goes
	// out with the strobes, and is done long before the next bus cycle)
	reg  as_d, asl_d, busy;
	wire start = (as || iack) && !as_d;
	wire as_loc = !ASn && !iack && (sel_loc || !eRWn);
	wire start_loc = as_loc && !asl_d;
	always @(posedge clk) begin as_d <= as || iack; asl_d <= as_loc; end

	// work RAM (two byte lanes) and the EEPROM (bytes on the low lane)
	reg  [7:0] ram_h [0:32767], ram_l [0:32767];
	reg  [7:0] eep   [0:8191] /*verilator public_flat_rw*/;
	reg  [15:0] ram_q;
	reg  [7:0]  eep_q;
	always @(posedge clk) begin
		if (wr && sel_ram && !UDSn) ram_h[a[15:1]] <= oEdb[15:8];
		if (wr && sel_ram && !LDSn) ram_l[a[15:1]] <= oEdb[7:0];
		ram_q <= {ram_h[a[15:1]], ram_l[a[15:1]]};
		if (wr && sel_eep && !LDSn) eep[a[13:1]] <= oEdb[7:0];
		if (nv_we) eep[nv_addr] <= nv_data;            // the download: the default NVRAM
		eep_q <= eep[a[13:1]];
	end
	assign rom_addr = a[17:1];
	assign rom_rd = !ASn && !iack && sel_rom && eRWn;

	// the C148: register strobes once per bus cycle
	wire [7:0] c148_q;
	ns2_c148 u_c148 (
		.clk(clk), .reset(reset), .cs(start && sel_c148), .we(!eRWn), .rd(eRWn), .addr(a[17:1]),
		.din(oEdb[7:0]), .dout(c148_q),
		.vblank(vblank), .posirq(posirq), .cpuirq_in(cpuirq_in), .cpuirq_out(cpuirq_out),
		.iack(start && iack), .iack_lvl(eab[3:1]), .ipl(ipl),
		.ext_in(3'b111), .ext1(ext1), .ext2(ext2), .bus_ctrl());   // ext_in: MAME leaves it unconnected (7)

	// DTACK: local devices two clocks after the start (the RAM and ROM have
	// answered), shared ones when the grant completes
	reg [2:0] lat;
	always @(posedge clk) begin
		if (cpu_reset) begin dtack <= 1'b0; sh_req <= 1'b0; busy <= 1'b0; lat <= 0; end
		else begin
			if (ASn) begin dtack <= 1'b0; busy <= 1'b0; end
			if (start_loc) begin busy <= 1'b1; lat <= 3'd2; end
			if (start) begin
				busy <= 1'b1;
				if (iack) begin
					iEdb <= {8'h00, 8'd24 + {5'd0, eab[3:1]}};
					lat <= 3'd2;
				end else if (!sel_loc) begin
					sh_req <= 1'b1; sh_addr <= eab; sh_we <= !eRWn; sh_uds <= !UDSn; sh_lds <= !LDSn; sh_dout <= oEdb;
				end
			end
			// a ROM read waits at its last count until the ROM is ready
			if (lat != 0 && !(lat == 3'd1 && sel_rom && !iack && !rom_ready)) begin
				lat <= lat - 1'd1;
				if (lat == 3'd1) begin
					dtack <= 1'b1;
					if (!iack) iEdb <= sel_rom ? rom_data : sel_ram ? ram_q : sel_eep ? {8'h00, eep_q} :
					                   {8'h00, c148_q};       // (umask16: the other lane 0)
				end
			end
			if (sh_req && sh_done) begin
				sh_req <= 1'b0;
				if (!sh_we) begin dtack <= 1'b1; iEdb <= sh_din; end
			end
		end
	end
endmodule
