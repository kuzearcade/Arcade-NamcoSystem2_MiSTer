// The two 68000s and their shared bus (namcos2.cpp: namcos2_68k_default_cpu_board_am,
// common_default_am, common_finallap_am): the arbiter grants one access at a
// time (master first when both ask in the same clock); an access takes three
// clocks (address and select; the device latches; capture and complete), far
// inside a 68000 bus cycle, so neither CPU waits (as in MAME).
//   200000-3fffff data ROM          400000-41ffff C123 tilemap (mirrored)
//   420000-42003f C123 control      440000-44ffff C116
//   460000-46ffff DPRAM (low byte, 2 KB, mirrored)
//   480000-483fff C139 RAM          4a0000-4a000f C139 registers
//   standard: c00000 sprites, c40000 gfx_ctrl, c80000 ROZ RAM, cc0000 ROZ control, d00000 key
//   Final Lap: 800000 sprites, 840000 gfx_ctrl, 880000-89ffff road, 300000 protection
module ns2_main (
	input             clk,
	input             reset,
	input      [2:0]  board,          // as ns2_video: 0 standard, 1 Final Lap
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	// program ROMs and the data ROM: data one clock after the address
	output     [17:1] mrom_addr,
	input      [15:0] mrom_data,
	input             mrom_ready,     // the ROMs' caches (M3); 1 with the arrays
	output            mrom_rd,
	output     [17:1] srom_addr,
	input      [15:0] srom_data,
	input             srom_ready,
	output            srom_rd,
	output     [20:1] drom_addr,
	input      [15:0] drom_data,
	input             drom_ready,
	output            drom_rd,
	input             nv_we,          // the NVRAM's port of the EEPROM (the download's default, the .nvm)
	input      [12:0] nv_addr,
	input      [7:0]  nv_data,
	output     [7:0]  nv_q,
	output            nv_cpu_we,      // the master writes the EEPROM
	output            cpu_hold,       // this clock, a 68000's ROM read waits for its cache
	input             stop,           // every CPU stops (any one's hold)
	// events
	input             vblank,
	input             posirq,
	output            sound_run,      // the master's C148 ext1
	output            sub_run,        // ext2: the slave and the MCU run
	// the video's CPU port (ns2_video)
	output reg [20:1] v_addr,
	output reg [15:0] v_dout,
	output reg        v_rnw,
	output reg        v_uds,
	output reg        v_lds,
	output reg        cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl,
	output reg        cs_c169, cs_c169ctl, cs_c355, cs_c355pos,
	input      [15:0] v_din,
	// the DPRAM's 68000 port (bytes)
	output reg [10:0] dp_addr,
	output reg [7:0]  dp_dout,
	output reg        dp_we,
	input      [7:0]  dp_din,
	// debug
	output            m_as, s_as,
	output     [23:1] m_addr, s_addr,
	output            m_rnw, s_rnw,
	output     [15:0] m_wdata, s_wdata,
	output     [1:0]  m_ds, s_ds,
	output     [15:0] m_rdata, s_rdata,
	output            m_dtack, s_dtack
);
	// 12.288 MHz: PHI1 and PHI2 alternate every two clocks. The phases stop,
	// for both CPUs, on a clock where a ROM read waits for its cache (a
	// program ROM's or the data ROM's): on the board the ROMs never make
	// either CPU wait, and the games' master / slave handshakes depend on
	// their lockstep (Rolling Thunder 2, NS2-14). Each CPU's DTACK counts
	// clocks, so a stop only brings a DTACK earlier in its phases, and a
	// DTACK is never late without the caches: their timing is M2's.
	// The stop covers every CPU (the board's: the MCU and the 6809 too, whose
	// timing against the 68000s the DPRAM handshakes see).
	reg [1:0] ph;
	wire       m_hold, s_hold, drom_hold;
	assign cpu_hold = m_hold || s_hold || drom_hold;
	always @(posedge clk) ph <= reset ? 2'd0 : stop ? ph : ph + 1'd1;
	wire en_phi1 = ph == 2'd0 && !stop, en_phi2 = ph == 2'd2 && !stop;

	wire        m_req, s_req, m_we, s_we, m_uds, s_uds, m_lds, s_lds;
	wire [23:1] m_sa, s_sa;
	wire [15:0] m_sd, s_sd;
	reg         m_done, s_done;
	reg  [15:0] sh_q;
	wire        m_irq, s_irq;
	wire [2:0]  ext1, ext2;
	assign sound_run = ext1[0];
	assign sub_run   = ext2[0];

	ns2_cpu #(.MASTER(1)) u_master (
		.clk(clk), .reset(reset), .run(1'b1), .en_phi1(en_phi1), .en_phi2(en_phi2),
		.rom_addr(mrom_addr), .rom_data(mrom_data), .rom_ready(mrom_ready), .rom_rd(mrom_rd), .rom_hold(m_hold),
		.nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data), .nv_q(nv_q), .nv_cpu_we(nv_cpu_we),
		.vblank(vblank), .posirq(posirq), .cpuirq_in(s_irq), .cpuirq_out(m_irq), .ext1(ext1), .ext2(ext2),
		.sh_req(m_req), .sh_addr(m_sa), .sh_we(m_we), .sh_uds(m_uds), .sh_lds(m_lds), .sh_dout(m_sd),
		.sh_done(m_done), .sh_din(sh_q),
		.dbg_as(m_as), .dbg_addr(m_addr), .dbg_rnw(m_rnw), .dbg_wdata(m_wdata), .dbg_ds(m_ds), .dbg_iack(), .dbg_rdata(m_rdata), .dbg_dtack(m_dtack));
	ns2_cpu #(.MASTER(0)) u_slave (
		.clk(clk), .reset(reset), .run(ext2[0]), .en_phi1(en_phi1), .en_phi2(en_phi2),
		.rom_addr(srom_addr), .rom_data(srom_data), .rom_ready(srom_ready), .rom_rd(srom_rd), .rom_hold(s_hold),
		.nv_we(1'b0), .nv_addr(13'd0), .nv_data(8'd0), .nv_q(), .nv_cpu_we(),
		.vblank(vblank), .posirq(posirq), .cpuirq_in(m_irq), .cpuirq_out(s_irq), .ext1(), .ext2(),
		.sh_req(s_req), .sh_addr(s_sa), .sh_we(s_we), .sh_uds(s_uds), .sh_lds(s_lds), .sh_dout(s_sd),
		.sh_done(s_done), .sh_din(sh_q),
		.dbg_as(s_as), .dbg_addr(s_addr), .dbg_rnw(s_rnw), .dbg_wdata(s_wdata), .dbg_ds(s_ds), .dbg_iack(), .dbg_rdata(s_rdata), .dbg_dtack(s_dtack));

	// the key custom
	wire [15:0] key_q;
	reg         key_rd, key_we;
	reg  [2:0]  key_off;
	ns2_key u_key (.clk(clk), .reset(reset), .table_in(key_table), .mode(key_mode),
		.cs(1'b1), .rd(key_rd), .we(key_we), .offset(key_off), .din(v_dout), .dout(key_q));

	// the C139's RAM (the serial link's; games test it)
	reg [7:0] sci_h [0:8191], sci_l [0:8191];
	reg [15:0] sci_q, sci_rq;

	// the arbiter: the grant with the address, then the devices' read
	// latency, then the capture (three clocks, the master first): the 68000
	// gets DTACK in time for no wait state, as in MAME
	reg        busy, who_r;         // who: 0 master, 1 slave
	reg  [1:0] step;
	reg [3:0]  dev;
	wire       fl = board == 3'd1;
	localparam D_NONE = 0, D_DROM = 1, D_VID = 2, D_DP = 3, D_SCI = 4, D_KEY = 5, D_PROT = 6;
	wire       grant_m = m_req && !m_done, grant_s = s_req && !s_done;
	wire       who = busy ? who_r : !grant_m;
	wire [23:0] ga = {who ? s_sa : m_sa, 1'b0};
	// the boards' maps (namcos2.cpp): the CPU board's, then each graphics board's
	//   0 standard: c00000 sprites, c40000 gfx_ctrl, c80000 ROZ RAM, cc0000 ROZ control, d00000 key
	//   1 Final Lap: 300000 protection, 800000 sprites, 840000 gfx_ctrl, 880000 road
	//   2 Metal Hawk: c00000 sprites, c40000 C169 RAM, d00000 C169 control, e00000 gfx_ctrl
	//   3 Steel Gunner 2: 800000 C355, a00000 key
	//   4 Suzuka 8 Hours: 800000 C355, 900000 its positions, a00000 road, f00000 key
	//   5 Lucky & Wild: Suzuka's, and c00000 C169 RAM, d00000 C169 control
	wire std = board == 3'd0, mh = board == 3'd2, sg = board == 3'd3, suz = board == 3'd4, lw = board == 3'd5;
	wire c355b = sg || suz || lw;
	// {tmap, tctl, pal, spr, gfx, roz (and road), rozctl, c169, c169ctl, c355, c355pos}
	function [10:0] vsel(input [23:0] x);
		vsel = {x[23:17] == 7'h20,                                                  // 400000-41ffff
		        x[23:6] == 18'h10800,                                               // 420000-42003f
		        x[23:16] == 8'h44,                                                  // 440000-44ffff
		        ((std || mh) && x[23:14] == 10'h300) || (fl && x[23:16] == 8'h80),
		        (std && x[23:1] == 23'h620000) || (fl && x[23:1] == 23'h420000) || (mh && x[23:1] == 23'h700000),
		        (std && x[23:17] == 7'h64) || (fl && x[23:17] == 7'h44) || ((suz || lw) && x[23:17] == 7'h50),
		        std && x[23:4] == 20'hcc000,
		        (mh && x[23:16] == 8'hc4) || (lw && x[23:16] == 8'hc0),
		        (mh || lw) && x[23:5] == 19'h68000,                                 // d00000-d0001f
		        c355b && x[23:17] == 7'h40 && x[16:0] < 17'h14200,                  // 800000-8141ff
		        (suz || lw) && x[23:3] == 21'h120000};                              // 900000-900007
	endfunction
	function [3:0] decode(input [23:0] x);
		if (fl && x[23:18] == 6'h0c)            decode = D_PROT;   // 300000-33ffff (inside the data ROM's window)
		else if (x[23:21] == 3'b001)            decode = D_DROM;   // 200000-3fffff
		else if (vsel(x) != 0)                  decode = D_VID;
		else if (x[23:16] == 8'h46)             decode = D_DP;     // 460000-46ffff
		else if (x[23:14] == 10'h120)           decode = D_SCI;    // 480000-483fff
		else if ((std && x[23:4] == 20'hd0000) || (sg && x[23:4] == 20'ha0000) || ((suz || lw) && x[23:3] == 21'h1e0000))
		                                        decode = D_KEY;    // d00000 / a00000 / f00000
		else                                    decode = D_NONE;
	endfunction
	assign drom_addr = ga[20:1];
	assign drom_rd = busy && step != 2'd0 && dev == D_DROM && v_rnw;
	// the capture step waiting for the data ROM's cache (the arbiter's hold)
	assign drom_hold = busy && step == 2'd2 && dev == D_DROM && v_rnw && !drom_ready;

	// its ports in Intel's RAM template: written with the grant, read every
	// clock (the grant's read is taken at step 1)
	wire sci_w = !reset && !busy && (grant_m || grant_s) && decode(ga) == D_SCI && (who ? s_we : m_we);
	always @(posedge clk) begin
		if (sci_w && (who ? s_uds : m_uds)) sci_h[ga[13:1]] <= (who ? s_sd : m_sd) >> 8;
		if (sci_w && (who ? s_lds : m_lds)) sci_l[ga[13:1]] <= (who ? s_sd : m_sd) & 8'hff;
		sci_rq <= {sci_h[ga[13:1]], sci_l[ga[13:1]]};
	end

	always @(posedge clk) begin
		m_done <= 1'b0; s_done <= 1'b0;
		key_rd <= 1'b0; key_we <= 1'b0; dp_we <= 1'b0;
		{cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl, cs_c169, cs_c169ctl, cs_c355, cs_c355pos} <= 11'd0;
		if (reset) begin busy <= 1'b0; step <= 2'd0; end
		else case (busy ? step : 2'd0)
			2'd0: if (grant_m || grant_s) begin
				// a new request: select the device (its select is active next clock)
				busy <= 1'b1; who_r <= who;
				dev <= decode(ga);
				v_addr <= ga[20:1]; v_dout <= who ? s_sd : m_sd; v_rnw <= !(who ? s_we : m_we);
				v_uds <= who ? s_uds : m_uds; v_lds <= who ? s_lds : m_lds;
				case (decode(ga))
					D_VID: {cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl, cs_c169, cs_c169ctl, cs_c355, cs_c355pos} <= vsel(ga);
					D_DP: begin
						dp_addr <= ga[11:1]; dp_dout <= (who ? s_sd : m_sd) & 8'hff;
						dp_we <= (who ? s_we : m_we) && (who ? s_lds : m_lds);
					end
					D_KEY: key_off <= ga[3:1];
					default: ;
				endcase
				step <= 2'd1;
			end
			2'd1: begin
				// the devices latch their read data (the video's RAMs, the DPRAM);
				// the key's strobe lands on the capture clock, after its value is taken
				sci_q <= sci_rq;
				if (dev == D_KEY) begin key_rd <= !(who ? s_we : m_we); key_we <= who ? s_we : m_we; end
				step <= 2'd2;
			end
			default: if (!(dev == D_DROM && v_rnw && !drom_ready)) begin
				// capture and complete (a data ROM read waits for its cache)
				case (dev)
					D_DROM: sh_q <= drom_data;
					D_VID:  sh_q <= v_din;
					D_DP:   sh_q <= {8'h00, dp_din};     // (MAME's umask16 reads: the other lane 0)
					D_SCI:  sh_q <= sci_q;
					D_KEY:  sh_q <= key_q;
					default: sh_q <= 16'h0000;
				endcase
				if (who) s_done <= 1'b1; else m_done <= 1'b1;
				busy <= 1'b0;
			end
		endcase
	end
endmodule
