// The whole board for M2's simulation (sim/rtl/ns2_frames): the two 68000s
// (ns2_main), the video (ns2_video), the I/O MCU (ns2_c65, or ns2_c68 with
// mcu_c68), the sound board
// (ns2_sound) and the 2 KB DPRAM they share. ROMS = 0 (M2): the ROMs are
// arrays (public, loaded by the testbench), read in a clock. ROMS = 1 (M3):
// each CPU's ROM is a cache (ns2_rom_cache) over an SDRAM client of ns2_mem,
// and the C140's voices a client of its own; the ports below. Either way the
// graphics ROM streams are ports.
// Line events, at the start of the line (MAME's scanline timer):
//   200 the MCU's IRQ1, 240 both C148s' VBLANK, (reg5 - 32) & 0xff POSIRQ.
module ns2_board #(parameter C140_MAME_RATE = 0, parameter ROMS = 0,
	parameter HAS_SPRA = 1, parameter HAS_ROZ = 1, parameter HAS_C45 = 1, parameter HAS_C169 = 1, parameter HAS_C355 = 1,
	parameter WRAM_SD = 0, parameter C169_MCACHE = HAS_C169 && !HAS_C355,
	parameter HAS_C65 = 1) (                // 0: every set the bitstream serves has the C68 (SZ, LW)
	input             clk,
	input             reset,
	input      [2:0]  board,
	input             mcu_c68,       // the I/O MCU is a C68 (M37450) instead of a C65
	input             tile_fl2,
	input             spr_fl,
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	// inputs (MAME's ports)
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,
	input      [63:0] analog,
	input             dbg_stall,      // ROMS = 0: the master's ROM not ready (M2's stall experiment)
	input             pause,          // the OSD's pause: every CPU stops (as the lockstep's hold), and the sound chips' clocks
	// the master's memory back door (high scores, cheats): hb_req stops the
	// CPUs (as the lockstep's hold, the sound running on); 8 clocks later
	// (the shared bus's last access done) hb_ok, and an access then reads
	// hb_q a clock after hb_addr, or writes hb_din with hb_we. The master's
	// byte addresses: 100000-10ffff the work RAM (WRAM_SD: through its cache),
	// 400000-41ffff the C123's RAM (its mirror)
	input             hb_req,
	output            hb_ok,
	input      [23:0] hb_addr,
	input             hb_we,
	input      [7:0]  hb_din,
	output     [7:0]  hb_q,
	// WRAM_SD (NS2-33): the work RAM is reached through its cache: hb_stall,
	// the access is not ready this clock (its user holds; a read's byte is
	// then a clock after its address of the clocks the user runs)
	output            hb_stall,
	output     [3:0]  dbg_holds,      // the lockstep's sources: {6809, C68, C65, 68000s}
	// video out
	output     [7:0]  red, green, blue,
	output            ce_pix,         // the pixel clock enable (red/green/blue are the pixel at hcnt/vcnt)
	output     [8:0]  out_x,
	output     [7:0]  out_y,
	output            out_valid,
	output     [8:0]  hcnt,
	output     [8:0]  vcnt,
	// the graphics ROM streams (as ns2_video)
	output            tile_req,  output [18:0] tile_addr,  input tile_ack,  input tile_valid,  input [63:0] tile_data,
	output            tmask_req, output [18:0] tmask_addr, input tmask_ack, input tmask_valid, input [7:0]  tmask_data,
	output            roz_req,   output [18:0] roz_addr,   input roz_ack,   input roz_valid,   input [63:0] roz_data,
	output            spr_req,   output [19:0] spr_addr,   input spr_ack,   input spr_valid,   input [63:0] spr_data,
	output            c169_req,  output [20:0] c169_addr,  input c169_ack,  input c169_valid,  input [63:0] c169_data,
	output            c169m_req, output [18:0] c169m_addr, input c169m_ack, input c169m_valid, input [63:0] c169m_data,
	// audio
	output signed [15:0] ym_left, ym_right,
	output            ym_sample,      // jt51's sample (high a YM cycle, 55.93 kHz)
	output signed [15:0] c140_left, c140_right, c140_raw_l, c140_raw_r,
	output            c140_sample,
	// debug
	output            m_as, s_as,
	output     [23:1] m_addr, s_addr,
	output            m_rnw, s_rnw,
	output     [15:0] m_wdata, s_wdata,
	output     [1:0]  m_ds, s_ds,
	output     [15:0] m_rdata, s_rdata,
	output            m_dtack, s_dtack,
	output     [15:0] mcu_addr, snd_addr,
	output            mcu_wr, snd_wr,
	// ROMS = 1: ns2_mem's clients (bursts of four words)
	output            mprog_req, output [14:0] mprog_addr, input mprog_ack, input mprog_valid,
	output            sprog_req, output [14:0] sprog_addr, input sprog_ack, input sprog_valid,
	output            drom_req,  output [17:0] drom_addr,  input drom_ack,  input drom_valid,
	output            aud_req,   output [14:0] aud_addr,   input aud_ack,   input aud_valid,
	output            mcu_req,   output [12:0] mcu_addr_m, input mcu_ack,   input mcu_valid,
	output            c140_req,  output [17:0] c140_addr,  input c140_ack,  input c140_valid,
	input      [63:0] bank0_data,
	input      [63:0] bank1_data,
	// WRAM_SD (ROMS = 1): bank 1 clients: [0] the master's work RAM, [1] the
	// slave's, [2] the C139's RAM
	output     [2:0]  wram_req,
	output     [2:0]  wram_we,
	output     [44:0] wram_addr,      // words in each 64 KB
	output     [47:0] wram_din,
	output     [5:0]  wram_dsn,
	input      [2:0]  wram_ack,
	input      [2:0]  wram_valid,
	// the download's loads: the C45 CLUT and the default NVRAM
	input             clut_we,
	input      [7:0]  clut_addr,
	input      [7:0]  clut_data,
	input             nv_we,
	input      [12:0] nv_addr,
	input      [7:0]  nv_data,
	output     [7:0]  nv_q,           // the EEPROM at nv_addr, a clock later (the NVRAM's save)
	output            nv_cpu_we,      // the game writes the EEPROM
	output            overrun,        // the video: a line not rendered in time (ns2_video)
	output     [5:0]  overrun_src,
	output     [11:0] line_busy_max,
	output            mcu_tap, mcu_sync, mcu_cen,  // the C68's bus (debug)
	output     [7:0]  mcu_din,
	output     [7:0]  mcu_dout, snd_dout,
	output            sound_run, sub_run,
	// the savestate (M5, rtl/savestate/savestate.sv's core side, docs/savestates.md).
	// ss_freeze parks the 68000s and the 6809 in their monitors; once both
	// 68000s wait on RESUME and the 6809 fetches its loop (a fixed point of
	// every CPU's phases), everything stops (the MCU wherever it is, its
	// flops are in the image), the line events, the C140 and the 120 Hz
	// timer too, until ss_resume. A load (ss_load) lets a CPU held in reset
	// out to park, and the MCU's flops be written, until the transfer is
	// over. The image, 16-bit words at ss_addr (data ss_rdata within 4
	// clocks; RD_LAT 5):
	//   00000 master work RAM    08000 slave work RAM   10000 C123 RAM
	//   18000 C116 (the palette and its registers)      20000 ROZ / road RAM
	//   30000 C169 RAM           40000 C355 RAM (0xa100) 50000 sprite RAM
	//   52000 C139 RAM           54000 EEPROM (bytes)   56000 DPRAM (bytes)
	//   58000 sound RAM (bytes)  5a000 C140 registers   5a200 YM2151 shadow
	//   5a300 the video's registers (00 C123, 20 gfx_ctrl, 28 ROZ, 30 C169, 40 C355)
	//   5a380 registers (00 master, 08 slave: ns2_cpu; 10 key; 20 sound; 40 C65; 60 C68)
	//   5a400 C65 RAM            5a600 C68 RAM          5a800 C140 voices (32 bytes each; 5ac00 words)
	input             ss_freeze,
	input             ss_resume,
	input             ss_active,
	input             ss_load,
	input      [19:0] ss_addr,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_rdata,
	output            ss_frozen,
	output            ss_parked,
	input             ss_replay,
	output            ss_replay_done,
	// the engine's handshake (VARLAT, needed with WRAM_SD): ss_rd asks for a
	// word, ss_wr writes one; ss_ack when it is in ss_rdata or written. The
	// work RAMs through their caches (WRAM_SD) take as long as a miss or a
	// full FIFO; every other region 5 clocks
	input             ss_rd,
	output reg        ss_ack
);
	wire [17:1] mra, sra;
	wire [20:1] dra;
	wire [17:0] ara;
	wire [12:0] ira;
	wire [14:0] ira68;
	wire [14:0] era;
	wire [15:0] mrq, srq, drq;
	wire [7:0]  arq, irq_q, erq;
	wire        m_rd, s_rd, d_rd, a_rd, mcu_rd;
	wire        m_ready, s_ready, d_ready, a_ready, mcu_ready;
	// the CPUs' lockstep (NS2-14): any CPU waiting for its ROM's cache stops
	// them all, so the caches never change the CPUs' timing against each other
	wire        hold_main, hold_65, hold_68, hold_snd;
	reg         frozen;             // the savestate's freeze (below)
	wire        cpu_stop = hold_main || hold_65 || hold_68 || hold_snd || pause || hb_req || frozen;
	// the back door: its own after 8 clocks of hb_req (the shared bus idle)
	reg  [3:0]  hb_wait;
	always @(posedge clk) hb_wait <= !hb_req || reset ? 4'd0 : hb_wait == 4'd8 ? hb_wait : hb_wait + 1'd1;
	assign      hb_ok = hb_wait == 4'd8;
	wire        hb_wram = hb_ok && hb_addr[23:16] == 8'h10;
	wire        hb_vid  = hb_ok && hb_addr[23:17] == 7'h20;
	wire [7:0]  hb_mq;
	reg         hb_rv, hb_a0;
	always @(posedge clk) begin hb_rv <= hb_vid; hb_a0 <= hb_addr[0]; end
	assign dbg_holds = {hold_snd, hold_68, hold_65, hold_main};
	wire        a_smp, smp_65, smp_68;     // the slow CPUs' ROM address phases (ns2_rom_cache SAMPLED)
	wire        mcu_smp = mcu_c68 ? smp_68 : smp_65;
	wire [15:0] a_65, a_68;
	wire [15:0] mcu_a = mcu_c68 ? a_68 : a_65;       // the MCU's bus address
	// the voice ROM
	wire        vr_req;
	wire [19:0] vr_addr;
	reg         vr_valid;
	reg  [15:0] vr_q;
	generate if (ROMS == 0) begin : g_arrays
		// ROMs (public, loaded by the testbench)
		reg [15:0] mrom [0:131071] /*verilator public_flat_rw*/;
		reg [15:0] srom [0:131071] /*verilator public_flat_rw*/;
		reg [15:0] drom [0:1048575] /*verilator public_flat_rw*/;
		reg [7:0]  arom [0:262143] /*verilator public_flat_rw*/;     // the sound ROM
		reg [15:0] vrom [0:1048575] /*verilator public_flat_rw*/;    // the C140's voices (the region's words)
		reg [7:0]  irom [0:32767]  /*verilator public_flat_rw*/;     // the MCU's ROM: the C65's internal (8 KB) or c68.bin
		reg [7:0]  erom [0:32767]  /*verilator public_flat_rw*/;     // its EPROM
		reg [15:0] mrq_r, srq_r, drq_r;
		reg [7:0]  arq_r, irq_r, erq_r;
		always @(posedge clk) begin
			mrq_r <= mrom[mra]; srq_r <= srom[sra]; drq_r <= drom[dra];
			arq_r <= arom[ara]; irq_r <= irom[mcu_c68 ? ira68 : {2'b00, ira}]; erq_r <= erom[era];
			vr_valid <= vr_req; vr_q <= vrom[vr_addr];
		end
		assign {mrq, srq, drq, arq, irq_q, erq} = {mrq_r, srq_r, drq_r, arq_r, irq_r, erq_r};
		// dbg_stall (simulation): the master's ROM as a cache that misses
		assign {m_ready, s_ready, d_ready, a_ready, mcu_ready} = {!dbg_stall, 4'b1111};
		assign {mprog_req, sprog_req, drom_req, aud_req, mcu_req, c140_req} = 6'd0;
		assign mprog_addr = 0; assign sprog_addr = 0; assign drom_addr = 0; assign aud_addr = 0; assign mcu_addr_m = 0; assign c140_addr = 0;
	end else begin : g_caches
		// the SDRAM words hold the image's even byte low; the 68000's ROMs and
		// the C140's region are big-endian words
		wire [15:0] mw, sw, dw, aw, uw;
		ns2_rom_cache #(.AW(17)) u_mc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(mra), .rd_in(m_rd), .data(mw), .ready(m_ready),
			.m_req(mprog_req), .m_addr(mprog_addr), .m_ack(mprog_ack), .m_valid(mprog_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(17)) u_sc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(sra), .rd_in(s_rd), .data(sw), .ready(s_ready),
			.m_req(sprog_req), .m_addr(sprog_addr), .m_ack(sprog_ack), .m_valid(sprog_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(20)) u_dc (.clk(clk), .rst(reset), .smp(1'b1), .addr_in(dra), .rd_in(d_rd), .data(dw), .ready(d_ready),
			.m_req(drom_req), .m_addr(drom_addr), .m_ack(drom_ack), .m_valid(drom_valid), .m_data(bank0_data));
		ns2_rom_cache #(.AW(17), .SAMPLED(1)) u_ac (.clk(clk), .rst(reset), .smp(a_smp), .addr_in(ara[17:1]), .rd_in(a_rd), .data(aw), .ready(a_ready),
			.m_req(aud_req), .m_addr(aud_addr), .m_ack(aud_ack), .m_valid(aud_valid), .m_data(bank0_data));
		// the MCU's 64 KB: its EPROM (the C65's 8000-ffff), then its internal
		// ROM (the C65's 0000-1fff, the C68's c68.bin at 8000-ffff)
		wire [15:0] ub = mcu_c68 ? {1'b1, mcu_a[14:0]} : mcu_a[15] ? {1'b0, mcu_a[14:0]} : {3'b100, mcu_a[12:0]};
		ns2_rom_cache #(.AW(15), .SAMPLED(1)) u_uc (.clk(clk), .rst(reset), .smp(mcu_smp), .addr_in(ub[15:1]), .rd_in(mcu_rd), .data(uw), .ready(mcu_ready),
			.m_req(mcu_req), .m_addr(mcu_addr_m), .m_ack(mcu_ack), .m_valid(mcu_valid), .m_data(bank0_data));
		assign mrq = {mw[7:0], mw[15:8]};
		assign srq = {sw[7:0], sw[15:8]};
		assign drq = {dw[7:0], dw[15:8]};
		// the byte of the word: the live address (the caches are ready only
		// while their word is the live one)
		assign arq = ara[0] ? aw[15:8] : aw[7:0];
		assign irq_q = ub[0] ? uw[15:8] : uw[7:0];
		assign erq = irq_q;
		// the C140: its request held until the bank takes it; the word of the burst
		reg        c_req;
		reg [17:0] c_addr;
		reg [1:0]  c_w;
		always @(posedge clk) begin
			vr_valid <= 1'b0;
			if (reset) c_req <= 1'b0;
			else begin
				if (vr_req) begin c_req <= 1'b1; c_addr <= vr_addr[19:2]; c_w <= vr_addr[1:0]; end
				if (c_req && c140_ack) c_req <= 1'b0;
				if (c140_valid) begin
					vr_valid <= 1'b1;
					vr_q <= {bank1_data[16 * c_w +: 8], bank1_data[16 * c_w + 8 +: 8]};
				end
			end
		end
		assign c140_req = c_req;
		assign c140_addr = c_addr;
	end endgenerate

	// ------------------------------------------------------------ the savestate
	wire        rg_mram  = ss_addr[19:15] == 5'h00, rg_sram = ss_addr[19:15] == 5'h01;
	wire        rg_tmap  = ss_addr[19:15] == 5'h02, rg_pal  = ss_addr[19:15] == 5'h03;
	wire        rg_roz   = ss_addr[19:16] == 4'h2,  rg_c169 = ss_addr[19:15] == 5'h06;
	wire        rg_c355  = ss_addr[19:16] == 4'h4,  rg_spr  = ss_addr[19:13] == 7'h28;
	wire        rg_sci   = ss_addr[19:13] == 7'h29, rg_eep  = ss_addr[19:13] == 7'h2a;
	wire        rg_dp    = ss_addr[19:11] == 9'h0ac, rg_aram = ss_addr[19:13] == 7'h2c;
	wire        rg_c140r = ss_addr[19:9] == 11'h2d0, rg_ym  = ss_addr[19:8] == 12'h5a2;
	wire        rg_vreg  = ss_addr[19:7] == 13'h0b46, rg_breg = ss_addr[19:7] == 13'h0b47;
	wire        rg_c65r  = ss_addr[19:9] == 11'h2d2, rg_c68r = ss_addr[19:9] == 11'h2d3;
	wire        rg_c140v = ss_addr[19:10] == 10'h16a;
	wire [6:0]  ss_idx   = ss_addr[6:0];
	wire        rb_cpu   = rg_breg && ss_idx[6:4] == 3'd0;            // 00-0f: the 68000s (08: the slave)
	wire        rb_key   = rg_breg && ss_idx[6:2] == 5'b00100;        // 10-13
	wire        rb_snd   = rg_breg && ss_idx[6:5] == 2'b01;           // 20-3f
	wire        rb_c65   = rg_breg && ss_idx[6:4] == 3'b100;          // 40-4f
	wire        rb_c68   = rg_breg && ss_idx[6:5] == 2'b11;           // 60-7f
	wire        rv_tctl  = rg_vreg && ss_idx[6:5] == 2'b00, rv_gfx = rg_vreg && ss_idx == 7'h20;
	wire        rv_roz   = rg_vreg && ss_idx[6:3] == 4'b0101, rv_c169 = rg_vreg && ss_idx[6:4] == 3'b011;
	wire        rv_c355  = rg_vreg && ss_idx[6:2] == 5'b10000;
	wire        ss_vid   = ss_active && (rg_tmap || rg_pal || rg_roz || rg_c169 || rg_c355 || rg_spr || rg_vreg);
	wire [19:0] ss_vaddr = rg_vreg ? {13'd0, ss_idx} : {4'd0, ss_addr[15:0]};
	wire [15:0] main_ssq, snd_ssq, c65_ssq, c68_ssq;
	// the handshake (above), and the caches emptied at the transfer's end
	// (a save and its load then resume with the same, empty, caches: their
	// misses stop every CPU)
	wire        ss_wready, ss_wfull;
	reg         ss_pend, ss_pw, ss_wgo, ss_act_d;
	reg  [2:0]  ss_cnt;
	wire        ss_wram = WRAM_SD && (rg_mram || rg_sram || rg_sci);
	always @(posedge clk) begin
		ss_ack <= 1'b0; ss_wgo <= 1'b0; ss_act_d <= ss_active;
		if (!ss_active) ss_pend <= 1'b0;
		else if (ss_rd || ss_wr) begin ss_pend <= 1'b1; ss_pw <= ss_wr; ss_cnt <= 3'd0; end
		else if (ss_pend) begin
			if (ss_wram && ss_pw) begin
				if (!ss_wfull && !ss_wgo) begin ss_wgo <= 1'b1; ss_ack <= 1'b1; ss_pend <= 1'b0; end
			end else if (ss_wram) begin
				if (ss_wready) begin ss_ack <= 1'b1; ss_pend <= 1'b0; end
			end else begin
				ss_cnt <= ss_cnt + 1'd1;
				if (ss_cnt == 3'd4) begin ss_ack <= 1'b1; ss_pend <= 1'b0; end
			end
		end
	end
	wire        ss_flush = ss_act_d && !ss_active;
	wire [15:0] v_din_w;
	wire        m_parked, s_parked, a_parked, m_stalled, s_stalled, s_running, at_head, e_fall, c140_idle;

	// the freeze: both 68000s on RESUME for 32 running clocks (in the wait
	// loop of the bus cycle, not its first states), and the 6809 fetching
	// its loop's head (a falling E: the 68000s' phases are then 0, as theirs
	// and the 6809's reset together), or a falling E while it is in reset
	reg  [5:0]  m_wait, s_wait;
	reg  [4:0]  frz_cnt;
	reg         ld_force;
	wire        a_running = sound_run || ld_force;
	always @(posedge clk) begin
		if (!m_stalled) m_wait <= 0; else if (!cpu_stop && m_wait != 6'd32) m_wait <= m_wait + 1'd1;
		if (!s_stalled) s_wait <= 0; else if (!cpu_stop && s_wait != 6'd32) s_wait <= s_wait + 1'd1;
	end
	wire        frz_go = ss_freeze && !ss_resume && !frozen && m_wait == 6'd32 && (s_wait == 6'd32 || !s_running) &&
	                     (a_running ? at_head : e_fall);
	always @(posedge clk) begin
		if (reset || !ss_freeze || ss_resume) frozen <= 1'b0;
		else if (frz_go) frozen <= 1'b1;
		frz_cnt <= !frozen ? 5'd0 : frz_cnt == 5'd31 ? frz_cnt : frz_cnt + 1'd1;
		// a load: the CPUs held in reset run to park, and the MCU's flops can
		// be written, until the image is in (its C148s then say who runs)
		if (reset || !ss_freeze || ss_resume || ss_replay) ld_force <= 1'b0;
		else if (ss_load && !frozen) ld_force <= 1'b1;
	end
	assign ss_frozen = frozen && frz_cnt == 5'd31 && c140_idle;
	assign ss_parked = m_parked || s_parked || a_parked;
	wire        ss_release = frozen && ss_resume;

	// line events
	wire       line_start = ce_pix && hcnt == 9'd383;     // the next clock starts a line
	reg        ev_vbl, ev_pos, ev_mcu;
	wire       pos_here;
	reg  [8:0] vnext;
	always @(posedge clk) begin
		ev_vbl <= 1'b0; ev_pos <= 1'b0; ev_mcu <= 1'b0;
		if (line_start) vnext <= vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
		// one clock after the counters moved to the new line
		if (ce_pix && hcnt == 9'd0 && !frozen) begin
			ev_vbl <= vcnt == 9'd240;
			ev_mcu <= vcnt == 9'd200;
			ev_pos <= pos_here;
		end
	end

	// the DPRAM: three users (68000s, sound, MCU) on a true dual port RAM.
	// Port A is the 68000s'. Port B alternates clocks between the sound CPU
	// and the MCU: each holds its address for a whole bus cycle (dozens of
	// clocks), so its read is at most three clocks old, and its write (a
	// one-clock pulse) waits for its turn, at most a clock.
	reg  [7:0] dpram [0:2047] /*verilator public_flat_rw*/;
	wire [10:0] dpa_m, dpa_s, dpa_u;
	wire [7:0]  dpd_m, dpd_s, dpd_u;
	wire        dpw_m, dpw_s, dpw_u;
	reg  [7:0]  dpq_m, dpq_s, dpq_u;
	// (the snapshot's while ss_active)
	wire [10:0] pa_m = ss_active ? ss_addr[10:0] : dpa_m;
	wire        pw_m = ss_active ? ss_wr && rg_dp : dpw_m;
	wire [7:0]  pd_m = ss_active ? ss_wdata[7:0] : dpd_m;
	always @(posedge clk)
		if (pw_m) begin dpram[pa_m] <= pd_m; dpq_m <= pd_m; end
		else dpq_m <= dpram[pa_m];
	reg         dp_t, dp_td;                // port B's turn: 0 sound, 1 MCU (and last clock's)
	reg         pw_s, pw_u;                 // a write waiting for its turn
	reg  [10:0] pa_s, pa_u;
	reg  [7:0]  pd_s, pd_u, dpq_b;
	wire        b_we = dp_t ? pw_u : pw_s;
	wire [10:0] b_a  = dp_t ? (pw_u ? pa_u : dpa_u) : (pw_s ? pa_s : dpa_s);
	wire [7:0]  b_d  = dp_t ? pd_u : pd_s;
	always @(posedge clk)
		if (b_we) begin dpram[b_a] <= b_d; dpq_b <= b_d; end
		else dpq_b <= dpram[b_a];
	always @(posedge clk) begin
		// (the savestate's release starts port B's turns over: the same turn
		// after a save and after its load)
		dp_t <= ss_release ? 1'b0 : ~dp_t; dp_td <= dp_t;
		if (b_we && dp_t) pw_u <= 1'b0;
		if (b_we && !dp_t) pw_s <= 1'b0;
		if (dpw_s) begin pw_s <= 1'b1; pa_s <= dpa_s; pd_s <= dpd_s; end
		if (dpw_u) begin pw_u <= 1'b1; pa_u <= dpa_u; pd_u <= dpd_u; end
		if (dp_td) dpq_u <= dpq_b; else dpq_s <= dpq_b;
		if (reset) begin pw_s <= 1'b0; pw_u <= 1'b0; end
	end

	// the 68000s
	wire [20:1] v_addr;
	wire [15:0] v_dout, v_din;
	wire        v_rnw, v_uds, v_lds, cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl;
	wire        cs_c169, cs_c169ctl, cs_c355, cs_c355pos;
	// the RAMs in the SDRAM (WRAM_SD): ns2_mem's clients, or (ROMS = 0) a
	// model of them, a burst eight clocks after its request
	wire [2:0]  wm_req, wm_we, wm_ack, wm_valid;
	wire [44:0] wm_addr;
	wire [47:0] wm_din;
	wire [5:0]  wm_dsn;
	wire [63:0] wm_data;
	generate if (WRAM_SD && ROMS == 0) begin : g_wram_model
		reg [15:0] wram [0:98303] /*verilator public_flat_rw*/;
		reg [2:0]  ack, val;
		reg [63:0] q;
		reg        busy;
		reg [1:0]  who;
		reg [16:0] line;
		reg [3:0]  cnt;
		integer    i;
		initial for (i = 0; i < 98304; i = i + 1) wram[i] = 16'h0000;
		wire [2:0] rq = wm_req & ~ack;
		wire [1:0] pick = rq[0] ? 2'd0 : rq[1] ? 2'd1 : 2'd2;
		wire [16:0] w_a = {pick, wm_addr[15 * pick +: 15]};
		wire [15:0] w_d = wm_din[16 * pick +: 16];
		wire [1:0]  w_m = wm_dsn[2 * pick +: 2];
		always @(posedge clk) begin
			ack <= 0; val <= 0;
			if (reset) busy <= 1'b0;
			else if (busy) begin
				cnt <= cnt - 1'd1;
				if (cnt == 0) begin
					busy <= 1'b0; val[who] <= 1'b1;
					q <= {wram[line + 3], wram[line + 2], wram[line + 1], wram[line]};
				end
			end else if (|rq) begin
				ack[pick] <= 1'b1;
				if (wm_we[pick]) begin
					if (!w_m[1]) wram[w_a][15:8] <= w_d[15:8];
					if (!w_m[0]) wram[w_a][7:0]  <= w_d[7:0];
				end else begin busy <= 1'b1; who <= pick; line <= w_a; cnt <= 4'd7; end
			end
		end
		assign wm_ack = ack; assign wm_valid = val; assign wm_data = q;
		assign {wram_req, wram_we, wram_addr, wram_din, wram_dsn} = 0;
	end else begin : g_wram_mem
		assign {wram_req, wram_we, wram_addr, wram_din, wram_dsn} = {wm_req, wm_we, wm_addr, wm_din, wm_dsn};
		assign wm_ack = wram_ack; assign wm_valid = wram_valid; assign wm_data = bank1_data;
	end endgenerate

	ns2_main #(.WRAM_SD(WRAM_SD)) u_main (
		.hb_on(hb_ok), .hb_addr(hb_addr[15:0]), .hb_we(hb_we && hb_wram), .hb_din(hb_din), .hb_q(hb_mq),
		.hb_sel(hb_wram), .hb_stall(hb_stall),
		.clk(clk), .reset(reset), .board(board), .key_table(key_table), .key_mode(key_mode),
		.wm_req(wm_req), .wm_we(wm_we), .wm_addr(wm_addr), .wm_din(wm_din), .wm_dsn(wm_dsn),
		.wm_ack(wm_ack), .wm_valid(wm_valid), .wm_data(wm_data),
		.mrom_addr(mra), .mrom_data(mrq), .mrom_ready(m_ready), .mrom_rd(m_rd),
		.srom_addr(sra), .srom_data(srq), .srom_ready(s_ready), .srom_rd(s_rd),
		.drom_addr(dra), .drom_data(drq), .drom_ready(d_ready), .drom_rd(d_rd),
		.nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data), .nv_q(nv_q), .nv_cpu_we(nv_cpu_we), .cpu_hold(hold_main), .stop(cpu_stop),
		.vblank(ev_vbl), .posirq(ev_pos), .sound_run(sound_run), .sub_run(sub_run),
		.v_addr(v_addr), .v_dout(v_dout), .v_rnw(v_rnw), .v_uds(v_uds), .v_lds(v_lds),
		.cs_tmap(cs_tmap), .cs_tctl(cs_tctl), .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_gfx(cs_gfx),
		.cs_roz(cs_roz), .cs_rozctl(cs_rozctl), .cs_c169(cs_c169), .cs_c169ctl(cs_c169ctl), .cs_c355(cs_c355), .cs_c355pos(cs_c355pos),
		.v_din(v_din),
		.dp_addr(dpa_m), .dp_dout(dpd_m), .dp_we(dpw_m), .dp_din(dpq_m),
		.m_as(m_as), .s_as(s_as), .m_addr(m_addr), .s_addr(s_addr), .m_rnw(m_rnw), .s_rnw(s_rnw),
		.m_wdata(m_wdata), .s_wdata(s_wdata), .m_ds(m_ds), .s_ds(s_ds),
		.m_rdata(m_rdata), .s_rdata(s_rdata), .m_dtack(m_dtack), .s_dtack(s_dtack),
		.park_req(ss_freeze), .resume(ss_resume), .force_run(ld_force),
		.m_parked(m_parked), .s_parked(s_parked), .m_stalled(m_stalled), .s_stalled(s_stalled), .s_run(s_running),
		.ss_on(ss_active), .ss_a(rg_breg ? {8'd0, ss_idx} : ss_addr[14:0]),
		.ss_mram(rg_mram), .ss_sram(rg_sram), .ss_eep(rg_eep), .ss_sci(rg_sci),
		.ss_mreg(rb_cpu && !ss_idx[3]), .ss_sreg(rb_cpu && ss_idx[3]), .ss_kreg(rb_key),
		.ss_wr(ss_wr), .ss_wdata(ss_wdata), .ss_q(main_ssq),
		.ss_rd(ss_pend && !ss_pw), .ss_wgo(ss_wgo), .ss_flush(ss_flush), .ss_wready(ss_wready), .ss_wfull(ss_wfull));

	assign hb_q = hb_rv ? (hb_a0 ? v_din[7:0] : v_din[15:8]) : hb_mq;
	assign v_din_w = v_din;

	// the video
	ns2_video #(.HAS_SPRA(HAS_SPRA), .HAS_ROZ(HAS_ROZ), .HAS_C45(HAS_C45), .HAS_C169(HAS_C169), .HAS_C355(HAS_C355),
		.C169_MCACHE(C169_MCACHE)) u_video (
		.clk(clk), .reset(reset), .board(board), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.dl_clut_we(clut_we), .dl_clut_addr(clut_addr), .dl_clut_data(clut_data),
		.hcnt(hcnt), .vcnt(vcnt), .ce_pix(ce_pix), .hblank(), .vblank(), .hsync(), .vsync(),
		.red(red), .green(green), .blue(blue), .out_x(out_x), .out_y(out_y), .out_valid(out_valid),
		.posirq_line(pos_here),
		// the savestate's transfer owns the CPU's port while ss_active (each
		// region selected throughout, written on ss_wr); the back door while
		// hb_ok (the C123's RAM only)
		.cpu_addr(ss_active ? ss_vaddr : hb_ok ? {5'd0, hb_addr[15:1]} : v_addr),
		.cpu_dout(ss_active ? ss_wdata : hb_ok ? {hb_din, hb_din} : v_dout),
		.cpu_rnw(ss_active ? !ss_wr : hb_ok ? !(hb_we && hb_vid) : v_rnw),
		.cpu_uds(ss_active ? 1'b1 : hb_ok ? !hb_addr[0] : v_uds), .cpu_lds(ss_active ? 1'b1 : hb_ok ? hb_addr[0] : v_lds),
		.cs_tmap(ss_active ? ss_vid && rg_tmap : hb_ok ? hb_vid : cs_tmap),
		.cs_tctl(ss_active ? ss_vid && rv_tctl : cs_tctl && !hb_ok), .cs_pal(ss_active ? ss_vid && rg_pal : cs_pal && !hb_ok),
		.cs_spr(ss_active ? ss_vid && rg_spr : cs_spr && !hb_ok), .cs_gfx(ss_active ? ss_vid && rv_gfx : cs_gfx && !hb_ok),
		.cs_roz(ss_active ? ss_vid && rg_roz : cs_roz && !hb_ok), .cs_rozctl(ss_active ? ss_vid && rv_roz : cs_rozctl && !hb_ok),
		.cs_c169ctl(ss_active ? ss_vid && rv_c169 : cs_c169ctl && !hb_ok), .cs_c169(ss_active ? ss_vid && rg_c169 : cs_c169 && !hb_ok),
		.cs_c355(ss_active ? ss_vid && rg_c355 : cs_c355 && !hb_ok), .cs_c355pos(ss_active ? ss_vid && rv_c355 : cs_c355pos && !hb_ok),
		.ss_on(ss_active),
		.cpu_din(v_din),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.overrun(overrun), .overrun_src(overrun_src), .line_busy_max(line_busy_max));

	// the I/O MCU: the C65 or the C68
	wire [10:0] dpa_65, dpa_68;
	wire [7:0]  dpd_65, dpd_68;
	wire        dpw_65, dpw_68;
	wire        w_65, w_68;
	wire [7:0]  d_65, d_68;
	wire        rd_65, rd_68;
	assign mcu_rd = mcu_c68 ? rd_68 : rd_65;
	generate if (HAS_C65) begin : g_c65
	ns2_c65 u_mcu (
		.clk(clk), .por(reset), .reset(reset || !(sub_run || ld_force) || mcu_c68), .irq_line200(ev_mcu), .rom_ready(mcu_ready), .rom_rd(rd_65), .rom_smp(smp_65), .rom_hold(hold_65), .stop(cpu_stop),
		.ss_on(ss_active), .ss_a(rg_breg ? {5'd0, ss_idx[3:0]} : ss_addr[8:0]), .ss_ram(rg_c65r), .ss_reg(rb_c65),
		.ss_wr(ss_wr), .ss_wdata(ss_wdata), .ss_q(c65_ssq),
		.irom_addr(ira), .irom_data(irq_q), .erom_addr(era), .erom_data(erq),
		.dp_addr(dpa_65), .dp_dout(dpd_65), .dp_we(dpw_65), .dp_din(dpq_u),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_addr(a_65), .dbg_wr(w_65), .dbg_dout(d_65));
	end else begin : g_no_c65
		assign {rd_65, smp_65, hold_65, dpw_65, w_65} = 5'd0;
		assign {ira, era, dpa_65, dpd_65, a_65, d_65, c65_ssq} = 0;
	end endgenerate
	ns2_c68 u_c68 (
		.clk(clk), .reset(reset || !(sub_run || ld_force) || !mcu_c68), .irq_line200(ev_mcu), .rom_ready(mcu_ready), .rom_rd(rd_68), .rom_smp(smp_68), .rom_hold(hold_68), .stop(cpu_stop),
		.ss_on(ss_active), .ss_a(rg_breg ? {4'd0, ss_idx[4:0]} : ss_addr[8:0]), .ss_ram(rg_c68r), .ss_reg(rb_c68),
		.ss_wr(ss_wr), .ss_wdata(ss_wdata), .ss_q(c68_ssq),
		.rom_addr(ira68), .rom_data(irq_q),
		.dp_addr(dpa_68), .dp_dout(dpd_68), .dp_we(dpw_68), .dp_din(dpq_u),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_addr(a_68), .dbg_wr(w_68), .dbg_dout(d_68), .dbg_tap(mcu_tap), .dbg_sync(mcu_sync), .dbg_cen(mcu_cen), .dbg_din(mcu_din));
	assign dpa_u = mcu_c68 ? dpa_68 : dpa_65;
	assign dpd_u = mcu_c68 ? dpd_68 : dpd_65;
	assign dpw_u = mcu_c68 ? dpw_68 : dpw_65;
	assign mcu_addr = mcu_c68 ? a_68 : a_65;
	assign mcu_wr   = mcu_c68 ? w_68 : w_65;
	assign mcu_dout = mcu_c68 ? d_68 : d_65;

	// the sound board
	ns2_sound #(.C140_MAME_RATE(C140_MAME_RATE)) u_sound (
		.clk(clk), .reset(reset), .run(a_running),
		.rom_addr(ara), .rom_data(arq), .rom_ready(a_ready), .rom_rd(a_rd), .rom_smp(a_smp), .rom_hold(hold_snd), .stop(cpu_stop), .pause(pause || frozen),
		.park_req(ss_freeze), .resume(ss_resume), .parked(a_parked), .at_head(at_head),
		.ss_on(ss_active), .ss_a(rg_breg ? {8'd0, ss_idx[4:0]} : ss_addr[12:0]),
		.ss_ram(rg_aram), .ss_c140r(rg_c140r), .ss_c140v(rg_c140v), .ss_ym(rg_ym), .ss_reg(rb_snd),
		.ss_wr(ss_wr), .ss_wdata(ss_wdata), .ss_q(snd_ssq), .ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.c140_idle(c140_idle), .e_fall(e_fall),
		.dp_addr(dpa_s), .dp_dout(dpd_s), .dp_we(dpw_s), .dp_din(dpq_s),
		.ym_left(ym_left), .ym_right(ym_right), .ym_sample(ym_sample),
		.vrom_req(vr_req), .vrom_addr(vr_addr), .vrom_valid(vr_valid), .vrom_data(vr_q),
		.c140_left(c140_left), .c140_right(c140_right), .c140_raw_l(c140_raw_l), .c140_raw_r(c140_raw_r),
		.c140_sample(c140_sample),
		.dbg_addr(snd_addr), .dbg_wr(snd_wr), .dbg_dout(snd_dout));

	// the snapshot's read (each source a clock or two after ss_addr)
	always @(posedge clk) begin
		if (rg_mram || rg_sram || rg_eep || rg_sci || rb_cpu || rb_key) ss_rdata <= main_ssq;
		else if (rg_tmap || rg_pal || (rg_spr && HAS_SPRA) || (rg_roz && (HAS_ROZ || HAS_C45)) || (rg_c169 && HAS_C169) ||
		         (rg_c355 && HAS_C355 && ss_addr[15:0] < 16'ha100) || rg_vreg) ss_rdata <= v_din_w;
		else if (rg_dp) ss_rdata <= {8'h00, dpq_m};
		else if (rg_aram || rg_c140r || rg_c140v || rg_ym || rb_snd) ss_rdata <= snd_ssq;
		else if (rg_c65r || rb_c65) ss_rdata <= c65_ssq;
		else if (rg_c68r || rb_c68) ss_rdata <= c68_ssq;
		else ss_rdata <= 16'h0000;
	end

endmodule
