// M5's savestate gate (docs/savestates.md): ns2_board with the savestate
// engine (rtl/savestate/savestate.sv, fixed read latency 5) and its DDR port
// brought out to the testbench (tb.cpp). The board's ports the gate does not
// use are tied off.
module ss_top #(parameter BOARD_HAS_SPRA = 1, parameter BOARD_HAS_ROZ = 1, parameter BOARD_HAS_C45 = 1,
	parameter BOARD_HAS_C169 = 1, parameter BOARD_HAS_C355 = 1) (
	input             clk,
	input             reset,
	input      [2:0]  board,
	input             mcu_c68,
	input             tile_fl2,
	input             spr_fl,
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,
	input      [63:0] analog,
	output     [7:0]  red, green, blue,
	output     [8:0]  out_x,
	output     [7:0]  out_y,
	output            out_valid,
	output     [8:0]  hcnt,
	output     [8:0]  vcnt,
	output            tile_req,  output [18:0] tile_addr,  input tile_ack,  input tile_valid,  input [63:0] tile_data,
	output            tmask_req, output [18:0] tmask_addr, input tmask_ack, input tmask_valid, input [7:0]  tmask_data,
	output            roz_req,   output [18:0] roz_addr,   input roz_ack,   input roz_valid,   input [63:0] roz_data,
	output            spr_req,   output [19:0] spr_addr,   input spr_ack,   input spr_valid,   input [63:0] spr_data,
	output            c169_req,  output [20:0] c169_addr,  input c169_ack,  input c169_valid,  input [63:0] c169_data,
	output            c169m_req, output [18:0] c169m_addr, input c169m_ack, input c169m_valid, input [63:0] c169m_data,
	output signed [15:0] ym_left, ym_right, c140_left, c140_right,
	// the CPUs' buses (the traces compared after each resume)
	output            m_as, s_as,
	output     [23:1] m_addr, s_addr,
	output            m_rnw, s_rnw,
	output     [15:0] m_wdata, s_wdata,
	output     [15:0] m_rdata, s_rdata,
	output            m_dtack, s_dtack,
	output     [15:0] mcu_addr, snd_addr,
	output            mcu_wr, snd_wr,
	output     [7:0]  mcu_dout, snd_dout,
	// the engine
	input             save_req,
	input             load_req,
	input      [1:0]  slot,
	output            ss_busy, ss_done_ok, ss_done_fail,
	output     [1:0]  ss_fail_code,
	output            ss_frz,         // the board is frozen (debug)
	output            dbg_freeze, dbg_active, dbg_resume, dbg_replay,
	output            ddr_we, ddr_rd,
	output     [28:0] ddr_addr,
	output     [63:0] ddr_din,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready
);
	wire        ss_freeze, ss_resume, ss_active, ss_wr, ss_rd, ss_frozen, ss_parked, ss_replay, ss_replay_done, ss_load;
	wire [19:0] ss_addr;
	wire [15:0] ss_rdata, ss_wdata;
	assign ss_frz = ss_frozen;
	assign {dbg_freeze, dbg_active, dbg_resume, dbg_replay} = {ss_freeze, ss_active, ss_resume, ss_replay};
	ns2_board #(.C140_MAME_RATE(1), .ROMS(0), .HAS_SPRA(BOARD_HAS_SPRA), .HAS_ROZ(BOARD_HAS_ROZ), .HAS_C45(BOARD_HAS_C45),
		.HAS_C169(BOARD_HAS_C169), .HAS_C355(BOARD_HAS_C355)) u_board (
		.clk(clk), .reset(reset), .board(board), .mcu_c68(mcu_c68), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.key_table(key_table), .key_mode(key_mode),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.dbg_stall(1'b0), .pause(1'b0),
		.hb_req(1'b0), .hb_ok(), .hb_addr(24'd0), .hb_we(1'b0), .hb_din(8'd0), .hb_q(), .dbg_holds(),
		.red(red), .green(green), .blue(blue), .ce_pix(), .out_x(out_x), .out_y(out_y), .out_valid(out_valid),
		.hcnt(hcnt), .vcnt(vcnt),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.ym_left(ym_left), .ym_right(ym_right), .ym_sample(), .c140_left(c140_left), .c140_right(c140_right),
		.c140_raw_l(), .c140_raw_r(), .c140_sample(),
		.m_as(m_as), .s_as(s_as), .m_addr(m_addr), .s_addr(s_addr), .m_rnw(m_rnw), .s_rnw(s_rnw),
		.m_wdata(m_wdata), .s_wdata(s_wdata), .m_ds(), .s_ds(), .m_rdata(m_rdata), .s_rdata(s_rdata),
		.m_dtack(m_dtack), .s_dtack(s_dtack), .mcu_addr(mcu_addr), .snd_addr(snd_addr), .mcu_wr(mcu_wr), .snd_wr(snd_wr),
		.mprog_req(), .mprog_addr(), .mprog_ack(1'b0), .mprog_valid(1'b0),
		.sprog_req(), .sprog_addr(), .sprog_ack(1'b0), .sprog_valid(1'b0),
		.drom_req(), .drom_addr(), .drom_ack(1'b0), .drom_valid(1'b0),
		.aud_req(), .aud_addr(), .aud_ack(1'b0), .aud_valid(1'b0),
		.mcu_req(), .mcu_addr_m(), .mcu_ack(1'b0), .mcu_valid(1'b0),
		.c140_req(), .c140_addr(), .c140_ack(1'b0), .c140_valid(1'b0),
		.bank0_data(64'd0), .bank1_data(64'd0),
		.wram_req(), .wram_we(), .wram_addr(), .wram_din(), .wram_dsn(), .wram_ack(3'd0), .wram_valid(3'd0),
		.clut_we(1'b0), .clut_addr(8'd0), .clut_data(8'd0), .nv_we(1'b0), .nv_addr(13'd0), .nv_data(8'd0), .nv_q(), .nv_cpu_we(),
		.overrun(), .overrun_src(), .line_busy_max(), .mcu_tap(), .mcu_sync(), .mcu_cen(), .mcu_din(),
		.mcu_dout(mcu_dout), .snd_dout(snd_dout), .sound_run(), .sub_run(),
		.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active), .ss_load(ss_load),
		.ss_addr(ss_addr), .ss_wr(ss_wr), .ss_wdata(ss_wdata), .ss_rdata(ss_rdata),
		.ss_frozen(ss_frozen), .ss_parked(ss_parked), .ss_replay(ss_replay), .ss_replay_done(ss_replay_done));
	savestate #(.SS_WORDS(20'h5ac00), .DDR_BASE(29'd0), .SLOT_STRIDE(29'h20000), .RD_LAT(5)) u_ss (
		.clk(clk), .reset(reset), .save_req(save_req), .load_req(load_req), .slot(slot),
		.vblank(vcnt >= 9'd224), .allow(!reset),
		.ss_freeze(ss_freeze), .ss_frozen(ss_frozen), .ss_parked(ss_parked), .ss_resume(ss_resume), .ss_active(ss_active),
		.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_rd(ss_rd), .ss_ack(1'b0), .ss_wdata(ss_wdata),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.busy(ss_busy), .done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(ss_load),
		.clk_ddr(clk), .ddr_busy(1'b0), .rot_we(1'b0), .ddr_we(ddr_we), .ddr_rd(ddr_rd), .ddr_addr(ddr_addr),
		.ddr_din(ddr_din), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready));
endmodule
