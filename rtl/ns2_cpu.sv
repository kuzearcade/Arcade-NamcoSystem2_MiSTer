// One of the two 68000s with its own bus (namcos2.cpp master_common_am /
// slave_common_am): fx68k at 12.288 MHz (a PHI1 and a PHI2 enable every 4
// clocks of the 49.152 MHz clk), its program ROM, 64 KB of work RAM (the
// slave's 0x100000-0x13ffff window mirrors it, NS2-4), the EEPROM (master
// only), its C148; every other address goes to the shared bus, one access
// at a time (the grant), completed long before the 68000 samples DTACK, so
// neither CPU waits, as in MAME (Q8 measures the board's real contention).
// Interrupt acknowledges are answered with the autovector 24 + level (MAME's
// m68000 with the C148 on the IPL lines).
// WRAM_SD = 1 (the NB bitstream): the work RAM is in the SDRAM behind a
// cache (ns2_wram_cache); a miss, or a write with the cache's FIFO full,
// holds the CPU as a ROM read's miss does.
module ns2_cpu #(parameter MASTER = 1, parameter WRAM_SD = 0) (
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
	output            rom_hold,       // this clock, a ROM read waits for its cache (ns2_main stops both CPUs' phases)
	// the EEPROM's load (the download's default NVRAM, master only)
	input             nv_we,
	input      [12:0] nv_addr,
	input      [7:0]  nv_data,
	output reg [7:0]  nv_q,           // the EEPROM at nv_addr, a clock later (the NVRAM's save)
	output            nv_cpu_we,      // the CPU writes the EEPROM
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
	// the work RAM's back door (high scores, cheats): while hb_on (the CPUs
	// stopped) it owns the RAM's port; hb_q is the byte at hb_addr a clock
	// later (the 68000's big-endian: an even address is the high lane).
	// WRAM_SD: not served (hb_q 0)
	input             hb_on,
	input      [15:0] hb_addr,
	input             hb_we,
	input      [7:0]  hb_din,
	output     [7:0]  hb_q,
	// WRAM_SD: the work RAM's SDRAM client (ns2_wram_cache)
	output            wm_req,
	output            wm_we,
	output     [14:0] wm_addr,
	output     [15:0] wm_din,
	output     [1:0]  wm_dsn,
	input             wm_ack,
	input             wm_valid,
	input      [63:0] wm_data,
	// debug: the bus cycle
	output            dbg_as,
	output     [23:1] dbg_addr,
	output            dbg_rnw,
	output     [15:0] dbg_wdata,
	output     [1:0]  dbg_ds,
	output            dbg_iack,
	output     [15:0] dbg_rdata,      // the data the CPU reads (valid with dbg_dtack)
	output            dbg_dtack,
	// the savestate (M5, rtl/savestate/ss_m68k_park.sv): park_req parks the
	// CPU in the monitor (a level-7 interrupt; the monitor at 0x5f8000, unmapped
	// on every board); `stalled` while it waits on the monitor's read of
	// RESUME (its DTACK withheld until resume). While ss_on the snapshot
	// owns the work RAM's port (ss_ram, words), the EEPROM's NVRAM port
	// (ss_eep, bytes) and the registers (ss_reg: 0-3 SSP and USP, 4-6 the
	// C148's); the RAMs' data a clock after ss_a
	input             park_req,
	input             resume,
	output            parked,
	output            stalled,
	input             ss_on,
	input      [14:0] ss_a,
	input             ss_ram, ss_eep, ss_reg,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output     [15:0] ss_ram_q,
	output     [7:0]  ss_eep_q,
	output     [15:0] ss_reg_q
);
	wire        eRWn, ASn, LDSn, UDSn, FC0, FC1, FC2;
	wire [15:0] oEdb;
	wire [23:1] eab;
	reg  [15:0] iEdb;
	reg         dtack;
	wire [2:0]  ipl, ipl_park;
	wire        cpu_reset = reset || !run;

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(cpu_reset), .pwrUp(reset),
		.enPhi1(en_phi1), .enPhi2(en_phi2),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(!dtack), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(!(ipl[0] | ipl_park[0])), .IPL1n(!(ipl[1] | ipl_park[1])), .IPL2n(!(ipl[2] | ipl_park[2])),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab));

	wire [23:0] a     = {eab, 1'b0};
	wire        as    = !ASn && (!UDSn || !LDSn);
	wire        iack  = !ASn && FC0 && FC1 && FC2;
	wire        rd    = as && eRWn && !iack;
	wire        wr    = as && !eRWn && !iack;
	assign dbg_as = as && !iack; assign dbg_addr = eab; assign dbg_rnw = eRWn;
	assign dbg_wdata = oEdb; assign dbg_ds = {!UDSn, !LDSn}; assign dbg_iack = iack;
	assign dbg_rdata = iEdb; assign dbg_dtack = dtack;

	// the savestate's park: its overlay (the monitor's window and the vector)
	// is a local device, read without the ROM's cache
	wire        mon_win, mon_stall;
	wire [15:0] mon_q, park_q;
	ss_m68k_park #(.MON_BASE(15'h2fc0)) u_park (
		.clk(clk), .reset(cpu_reset), .phi(en_phi2),
		.park_req(park_req), .parked(parked), .resume(resume),
		.eab(eab), .ASn(ASn), .eRWn(eRWn), .FC0(FC0), .FC1(FC1), .FC2(FC2), .oEdb(oEdb),
		.ipl_park(ipl_park), .sel_mon(), .in_win(mon_win), .stall(mon_stall), .mon_data(mon_q),
		.ss_sel(ss_a[1:0]), .ss_wr(ss_wr && ss_reg && !ss_a[2]), .ss_wdata(ss_wdata), .ss_rdata(park_q));
	assign stalled = mon_stall;

	// local devices
	wire sel_mon  = mon_win;
	wire sel_rom  = a[23:18] == 6'h00 && !sel_mon;              // 000000-03ffff
	wire sel_ram  = a[23:18] == 6'h04;                          // 100000-13ffff (64 KB, mirrored)
	wire sel_eep  = MASTER && a[23:14] == 10'h060;              // 180000-183fff
	wire sel_c148 = a[23:18] == 6'h07;                          // 1c0000-1fffff
	wire sel_loc  = sel_rom || sel_ram || sel_eep || sel_c148 || sel_mon;

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

	reg [2:0] lat;                // DTACK's count (below)

	// work RAM (two byte lanes) and the EEPROM (bytes on the low lane)
	reg  [7:0] eep   [0:8191] /*verilator public_flat_rw*/;
	wire [15:0] ram_q;
	wire        ram_hold;
	reg  [7:0]  eep_q;
	generate if (WRAM_SD == 0) begin : g_ram
		reg  [7:0] ram_h [0:32767], ram_l [0:32767];
		reg  [15:0] q;
		reg         hb_a0;
		wire [14:0] ra  = ss_on ? ss_a : hb_on ? hb_addr[15:1] : a[15:1];
		wire        w_h = ss_on ? ss_wr && ss_ram : hb_on ? hb_we && !hb_addr[0] : wr && sel_ram && !UDSn;
		wire        w_l = ss_on ? ss_wr && ss_ram : hb_on ? hb_we &&  hb_addr[0] : wr && sel_ram && !LDSn;
		wire [7:0]  d_h = ss_on ? ss_wdata[15:8] : hb_on ? hb_din : oEdb[15:8];
		wire [7:0]  d_l = ss_on ? ss_wdata[7:0]  : hb_on ? hb_din : oEdb[7:0];
		always @(posedge clk) begin
			if (w_h) ram_h[ra] <= d_h;
			if (w_l) ram_l[ra] <= d_l;
			q <= {ram_h[ra], ram_l[ra]};
			hb_a0 <= hb_addr[0];
		end
		assign ram_q = q;
		assign ss_ram_q = q;
		assign hb_q  = hb_a0 ? q[7:0] : q[15:8];
		assign ram_hold = 1'b0;
		assign {wm_req, wm_we, wm_addr, wm_din, wm_dsn} = 0;
	end else begin : g_wram
		// the write goes to the cache once a bus cycle, with its strobes
		reg  w_done;
		wire w_go = wr && sel_ram && !w_done;
		always @(posedge clk) if (ASn) w_done <= 1'b0; else if (w_go) w_done <= 1'b1;
		wire ready, wfull;
		ns2_wram_cache u_wc (.clk(clk), .rst(reset), .addr(a[15:1]), .rd(rd && sel_ram), .wr(w_go),
			.wdata(oEdb), .wbe({!UDSn, !LDSn}), .q(ram_q), .ready(ready), .wfull(wfull),
			.m_req(wm_req), .m_we(wm_we), .m_addr(wm_addr), .m_din(wm_din), .m_dsn(wm_dsn),
			.m_ack(wm_ack), .m_valid(wm_valid), .m_data(wm_data));
		// at DTACK's count, as a ROM read: a read waits for its line, a
		// write for room in the FIFO (its strobes come later, the FIFO only drains)
		assign ram_hold = lat == 3'd1 && sel_ram && !iack && (eRWn ? !ready : wfull);
		assign hb_q = 8'd0;
		assign ss_ram_q = 16'd0;
	end endgenerate
	// the EEPROM: the CPU's port, and the NVRAM's (the download's default,
	// the .nvm's load and save); a write returns its own data (Intel's
	// true dual port template)
	assign nv_cpu_we = wr && sel_eep && !LDSn;
	always @(posedge clk)
		if (nv_cpu_we) begin eep[a[13:1]] <= oEdb[7:0]; eep_q <= oEdb[7:0]; end
		else eep_q <= eep[a[13:1]];
	// (the snapshot's while ss_on)
	wire [12:0] nv_a  = ss_on ? ss_a[12:0] : nv_addr;
	wire        nv_w  = ss_on ? ss_wr && ss_eep : nv_we;
	wire [7:0]  nv_d  = ss_on ? ss_wdata[7:0] : nv_data;
	always @(posedge clk)
		if (nv_w) begin eep[nv_a] <= nv_d; nv_q <= nv_d; end
		else nv_q <= eep[nv_a];
	assign ss_eep_q = nv_q;
	assign rom_addr = a[17:1];
	assign rom_rd = !ASn && !iack && sel_rom && eRWn;

	// the C148: register strobes once per bus cycle
	wire [7:0] c148_q;
	wire [15:0] c148_ss;
	assign ss_reg_q = ss_a[2] ? c148_ss : park_q;
	ns2_c148 u_c148 (
		.ss_sel(ss_a[1:0]), .ss_wr(ss_wr && ss_reg && ss_a[2]), .ss_wdata(ss_wdata), .ss_rdata(c148_ss),
		.clk(clk), .reset(reset), .cs(start && sel_c148), .we(!eRWn), .rd(eRWn), .addr(a[17:1]),
		.din(oEdb[7:0]), .dout(c148_q),
		.vblank(vblank), .posirq(posirq), .cpuirq_in(cpuirq_in), .cpuirq_out(cpuirq_out),
		.iack(start && iack), .iack_lvl(eab[3:1]), .ipl(ipl),
		.ext_in(3'b111), .ext1(ext1), .ext2(ext2), .bus_ctrl());   // ext_in: MAME leaves it unconnected (7)

	// DTACK: local devices two clocks after the start (the RAM and ROM have
	// answered), shared ones when the grant completes (lat: above)
	// a read only: a write to the program ROM (Rolling Thunder 2's slave
	// writes 001000) asks nothing of the cache, and the board ignores it
	assign rom_hold = (lat == 3'd1 && sel_rom && !iack && eRWn && !rom_ready) || ram_hold;
	// the monitor's read of RESUME waits (this CPU only) until the release
	wire mon_wait = lat == 3'd1 && mon_stall;
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
			if (lat != 0 && !rom_hold && !mon_wait) begin
				lat <= lat - 1'd1;
				if (lat == 3'd1) begin
					dtack <= 1'b1;
					if (!iack) iEdb <= sel_mon ? mon_q : sel_rom ? rom_data : sel_ram ? ram_q : sel_eep ? {8'h00, eep_q} :
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
