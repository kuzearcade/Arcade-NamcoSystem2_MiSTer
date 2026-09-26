// The whole board for M2's simulation (sim/rtl/ns2_frames): the two 68000s
// (ns2_main), the video (ns2_video), the I/O MCU (ns2_c65, or ns2_c68 with
// mcu_c68), the sound board
// (ns2_sound) and the 2 KB DPRAM they share. The ROMs are arrays here
// (public, loaded by the testbench); the graphics ROM streams are the
// testbench's, as in M1. M3 replaces the arrays with the SDRAM path.
// Line events, at the start of the line (MAME's scanline timer):
//   200 the MCU's IRQ1, 240 both C148s' VBLANK, (reg5 - 32) & 0xff POSIRQ.
module ns2_board #(parameter C140_MAME_RATE = 0) (
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
	// video out
	output     [7:0]  red, green, blue,
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
	// audio
	output signed [15:0] ym_left, ym_right,
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
	output            mcu_tap, mcu_sync, mcu_cen,  // the C68's bus (debug)
	output     [7:0]  mcu_din,
	output     [7:0]  mcu_dout, snd_dout,
	output            sound_run, sub_run
);
	// ROMs (public, loaded by the testbench)
	reg [15:0] mrom [0:131071] /*verilator public_flat_rw*/;
	reg [15:0] srom [0:131071] /*verilator public_flat_rw*/;
	reg [15:0] drom [0:1048575] /*verilator public_flat_rw*/;
	reg [7:0]  arom [0:262143] /*verilator public_flat_rw*/;     // the sound ROM
	reg [15:0] vrom [0:1048575] /*verilator public_flat_rw*/;    // the C140's voices (the region's words)
	reg [7:0]  irom [0:32767]  /*verilator public_flat_rw*/;     // the MCU's ROM: the C65's internal (8 KB) or c68.bin
	reg [7:0]  erom [0:32767]  /*verilator public_flat_rw*/;     // its EPROM
	wire [17:1] mra, sra;
	wire [20:1] dra;
	wire [17:0] ara;
	wire [12:0] ira;
	wire [14:0] ira68;
	wire [14:0] era;
	reg  [15:0] mrq, srq, drq;
	reg  [7:0]  arq, irq_q, erq;
	always @(posedge clk) begin
		mrq <= mrom[mra]; srq <= srom[sra]; drq <= drom[dra];
		arq <= arom[ara]; irq_q <= irom[mcu_c68 ? ira68 : {2'b00, ira}]; erq <= erom[era];
	end

	// line events
	wire       ce_pix;
	wire       line_start = ce_pix && hcnt == 9'd383;     // the next clock starts a line
	reg        ev_vbl, ev_pos, ev_mcu;
	wire       pos_here;
	reg  [8:0] vnext;
	always @(posedge clk) begin
		ev_vbl <= 1'b0; ev_pos <= 1'b0; ev_mcu <= 1'b0;
		if (line_start) vnext <= vcnt == 9'd263 ? 9'd0 : vcnt + 1'd1;
		// one clock after the counters moved to the new line
		if (ce_pix && hcnt == 9'd0) begin
			ev_vbl <= vcnt == 9'd240;
			ev_mcu <= vcnt == 9'd200;
			ev_pos <= pos_here;
		end
	end

	// the DPRAM: three ports (68000s, sound, MCU)
	reg  [7:0] dpram [0:2047] /*verilator public_flat_rw*/;
	wire [10:0] dpa_m, dpa_s, dpa_u;
	wire [7:0]  dpd_m, dpd_s, dpd_u;
	wire        dpw_m, dpw_s, dpw_u;
	reg  [7:0]  dpq_m, dpq_s, dpq_u;
	always @(posedge clk) begin
		if (dpw_m) dpram[dpa_m] <= dpd_m;
		if (dpw_s) dpram[dpa_s] <= dpd_s;
		if (dpw_u) dpram[dpa_u] <= dpd_u;
		dpq_m <= dpram[dpa_m]; dpq_s <= dpram[dpa_s]; dpq_u <= dpram[dpa_u];
	end

	// the 68000s
	wire [20:1] v_addr;
	wire [15:0] v_dout, v_din;
	wire        v_rnw, v_uds, v_lds, cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl;
	ns2_main u_main (
		.clk(clk), .reset(reset), .board(board), .key_table(key_table), .key_mode(key_mode),
		.mrom_addr(mra), .mrom_data(mrq), .srom_addr(sra), .srom_data(srq), .drom_addr(dra), .drom_data(drq),
		.vblank(ev_vbl), .posirq(ev_pos), .sound_run(sound_run), .sub_run(sub_run),
		.v_addr(v_addr), .v_dout(v_dout), .v_rnw(v_rnw), .v_uds(v_uds), .v_lds(v_lds),
		.cs_tmap(cs_tmap), .cs_tctl(cs_tctl), .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_gfx(cs_gfx),
		.cs_roz(cs_roz), .cs_rozctl(cs_rozctl), .v_din(v_din),
		.dp_addr(dpa_m), .dp_dout(dpd_m), .dp_we(dpw_m), .dp_din(dpq_m),
		.m_as(m_as), .s_as(s_as), .m_addr(m_addr), .s_addr(s_addr), .m_rnw(m_rnw), .s_rnw(s_rnw),
		.m_wdata(m_wdata), .s_wdata(s_wdata), .m_ds(m_ds), .s_ds(s_ds),
		.m_rdata(m_rdata), .s_rdata(s_rdata), .m_dtack(m_dtack), .s_dtack(s_dtack));

	// the video
	ns2_video u_video (
		.clk(clk), .reset(reset), .board(board), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.hcnt(hcnt), .vcnt(vcnt), .ce_pix(ce_pix), .hblank(), .vblank(), .hsync(), .vsync(),
		.red(red), .green(green), .blue(blue), .out_x(out_x), .out_y(out_y), .out_valid(out_valid),
		.posirq_line(pos_here),
		.cpu_addr(v_addr), .cpu_dout(v_dout), .cpu_rnw(v_rnw), .cpu_uds(v_uds), .cpu_lds(v_lds),
		.cs_tmap(cs_tmap), .cs_tctl(cs_tctl), .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_gfx(cs_gfx),
		.cs_roz(cs_roz), .cs_rozctl(cs_rozctl), .cs_c169ctl(1'b0), .cs_c169(1'b0), .cs_c355(1'b0), .cs_c355pos(1'b0),
		.cpu_din(v_din),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.c169_req(), .c169_addr(), .c169_ack(1'b0), .c169_valid(1'b0), .c169_data(64'd0),
		.c169m_req(), .c169m_addr(), .c169m_ack(1'b0), .c169m_valid(1'b0), .c169m_data(8'd0),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.overrun(), .overrun_src(), .line_busy_max());

	// the I/O MCU: the C65 or the C68
	wire [10:0] dpa_65, dpa_68;
	wire [7:0]  dpd_65, dpd_68;
	wire        dpw_65, dpw_68;
	wire [15:0] a_65, a_68;
	wire        w_65, w_68;
	wire [7:0]  d_65, d_68;
	ns2_c65 u_mcu (
		.clk(clk), .por(reset), .reset(reset || !sub_run || mcu_c68), .irq_line200(ev_mcu),
		.irom_addr(ira), .irom_data(irq_q), .erom_addr(era), .erom_data(erq),
		.dp_addr(dpa_65), .dp_dout(dpd_65), .dp_we(dpw_65), .dp_din(dpq_u),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_addr(a_65), .dbg_wr(w_65), .dbg_dout(d_65));
	ns2_c68 u_c68 (
		.clk(clk), .reset(reset || !sub_run || !mcu_c68), .irq_line200(ev_mcu),
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
		.clk(clk), .reset(reset), .run(sound_run),
		.rom_addr(ara), .rom_data(arq),
		.dp_addr(dpa_s), .dp_dout(dpd_s), .dp_we(dpw_s), .dp_din(dpq_s),
		.ym_left(ym_left), .ym_right(ym_right), .ym_sample(),
		.vrom_req(vr_req), .vrom_addr(vr_addr), .vrom_valid(vr_valid), .vrom_data(vr_q),
		.c140_left(c140_left), .c140_right(c140_right), .c140_raw_l(c140_raw_l), .c140_raw_r(c140_raw_r),
		.c140_sample(c140_sample),
		.dbg_addr(snd_addr), .dbg_wr(snd_wr), .dbg_dout(snd_dout));

	// the voice ROM: one clock
	wire        vr_req;
	wire [19:0] vr_addr;
	reg         vr_valid;
	reg  [15:0] vr_q;
	always @(posedge clk) begin vr_valid <= vr_req; vr_q <= vrom[vr_addr]; end
endmodule
