// M3's harness top (docs/PLAN.md M3): the board with its ROMs in the SDRAM
// (ns2_board ROMS = 1), ns2_mem, ns2_sdram and the burst SDRAM model, on the
// core's clock (clk, 49.152 MHz) and the SDRAM's (clk_sd, twice it). The
// testbench downloads the set's image through dl_*, then runs the board.
module top #(
	// a bitstream's blocks (NamcoS2.sv): make VARIANT=SG|MH|SZ|LW
	parameter HAS_SPRA = 1, parameter HAS_ROZ = 1, parameter HAS_C45 = 1, parameter HAS_C169 = 1, parameter HAS_C355 = 1,
	parameter WRAM_SD = 0, parameter SD_CL = 2, parameter SD_XRC = 0
) (
	input             clk,
	input             clk_sd,
	input             rst,            // the SDRAM's
	input             reset,          // the board's
	input             rfsh,
	output            sd_init,
	// the download
	input             dl,
	input             dl_wr,
	input      [24:0] dl_addr,
	input      [15:0] dl_data,
	output            dl_wait,
	// the board's configuration and inputs
	input      [2:0]  board,
	input             mcu_c68,
	input             tile_fl2,
	input             spr_fl,
	input             mh_wiring,
	input             lw_wiring,
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,
	input      [63:0] analog,
	// out
	output     [7:0]  red, green, blue,
	output     [8:0]  out_x,
	output     [7:0]  out_y,
	output            out_valid,
	output     [8:0]  hcnt,
	output     [8:0]  vcnt,
	output signed [15:0] c140_raw_l, c140_raw_r,
	output signed [15:0] ym_l,
	output     [15:0] snd_addr,
	output            snd_wr,
	output     [7:0]  snd_dout,
	output            sound_run,
	output     [3:0]  dbg_holds,
	output            c140_sample,
	output            m_as, m_dtack, m_rnw, s_as, s_dtack, s_rnw,
	output     [23:1] s_addr,
	output     [15:0] s_rdata, s_wdata,
	output     [1:0]  s_ds,
	output     [23:1] m_addr,
	output     [15:0] m_rdata, m_wdata,
	output     [1:0]  m_ds,
	output     [15:0] mcu_addr,
	output            mcu_wr,
	output     [7:0]  mcu_dout,
	output            mcu_cen,
	output     [31:0] violations,
	output            overrun,
	output     [5:0]  overrun_src,
	output     [11:0] line_busy_max,
	// the tile and mask streams (the testbench checks them against the image)
	output            dbg_t_ack, dbg_t_valid, dbg_m_ack, dbg_m_valid,
	output     [18:0] dbg_t_addr, dbg_m_addr,
	output     [63:0] dbg_t_data,
	output     [7:0]  dbg_m_data,
	output     [31:0] flt_t, flt_t_miss, flt_m, flt_m_miss
);
	assign {flt_t, flt_t_miss, flt_m, flt_m_miss} = {n_t, n_t_miss, n_m, n_m_miss};
	assign dbg_t_ack = tile_ack; assign dbg_t_valid = tile_valid; assign dbg_t_addr = tile_addr; assign dbg_t_data = tile_data;
	assign dbg_m_ack = tmask_ack; assign dbg_m_valid = tmask_valid; assign dbg_m_addr = tmask_addr; assign dbg_m_data = tmask_data;
	// the board
	wire        tile_req, tmask_req, roz_req, c169_req, c169m_req, spr_req;
	wire [18:0] tile_addr, tmask_addr, roz_addr, c169m_addr;
	wire [20:0] c169_addr;
	wire [19:0] spr_addr;
	wire        tile_ack, tmask_ack, roz_ack, c169_ack, c169m_ack, spr_ack;
	wire        tile_valid, tmask_valid, roz_valid, c169_valid, c169m_valid, spr_valid;
	wire [63:0] tile_data, roz_data, c169_data, spr_data;
	wire [7:0]  tmask_data;
	wire [63:0] c169m_data;
	wire        mprog_req, sprog_req, drom_req, aud_req, mcu_req, c140_req;
	wire [14:0] mprog_addr, sprog_addr, aud_addr;
	wire [17:0] drom_addr, c140_addr;
	wire [12:0] mcu_addr_m;
	wire        mprog_ack, sprog_ack, drom_ack, aud_ack, mcu_ack, c140_ack;
	wire        mprog_valid, sprog_valid, drom_valid, aud_valid, mcu_valid, c140_valid;
	wire [63:0] bank0_data, bank1_data;
	wire [2:0]  wram_req, wram_we, wram_ack, wram_valid;
	wire [44:0] wram_addr;
	wire [47:0] wram_din;
	wire [5:0]  wram_dsn;
	wire        clut_we, nv_we, class_we;
	// the filter's side of bank 2 (ns2_tile_filter)
	wire        ft_req, ft_ack, ft_valid, fm_req, fm_ack, fm_valid;
	wire [18:0] ft_addr;
	wire [15:0] fm_addr;
	wire [63:0] ft_data, fm_data;
	wire [31:0] n_t, n_t_miss, n_m, n_m_miss;
	wire [7:0]  clut_addr, clut_data, nv_data;
	wire [12:0] nv_addr;
	wire [15:0] class_addr;
	wire [1:0]  class_data;

	ns2_board #(.C140_MAME_RATE(1), .ROMS(1), .HAS_SPRA(HAS_SPRA), .HAS_ROZ(HAS_ROZ), .HAS_C45(HAS_C45),
		.HAS_C169(HAS_C169), .HAS_C355(HAS_C355), .WRAM_SD(WRAM_SD)) u_board ( .pause(1'b0), .hb_req(1'b0), .hb_ok(), .hb_addr(24'd0), .hb_we(1'b0), .hb_din(8'd0), .hb_q(),
		.ss_freeze(1'b0), .ss_resume(1'b0), .ss_active(1'b0), .ss_load(1'b0), .ss_addr(20'd0), .ss_wr(1'b0), .ss_wdata(16'd0),
		.ss_rdata(), .ss_frozen(), .ss_parked(), .ss_replay(1'b0), .ss_replay_done(), .ss_rd(1'b0), .ss_ack(),
		.clk(clk), .reset(reset || dl), .board(board), .mcu_c68(mcu_c68), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.key_table(key_table), .key_mode(key_mode),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog), .dbg_stall(1'b0), .dbg_holds(dbg_holds),
		.red(red), .green(green), .blue(blue), .out_x(out_x), .out_y(out_y), .out_valid(out_valid), .hcnt(hcnt), .vcnt(vcnt),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.ym_left(ym_l), .ym_right(), .c140_left(), .c140_right(), .c140_raw_l(c140_raw_l), .c140_raw_r(c140_raw_r), .c140_sample(c140_sample),
		.m_as(m_as), .s_as(s_as), .m_addr(m_addr), .s_addr(s_addr), .m_rnw(m_rnw), .s_rnw(s_rnw), .m_wdata(m_wdata), .s_wdata(s_wdata), .m_ds(m_ds), .s_ds(s_ds),
		.m_rdata(m_rdata), .s_rdata(s_rdata), .m_dtack(m_dtack), .s_dtack(s_dtack),
		.mcu_addr(mcu_addr), .snd_addr(snd_addr), .mcu_wr(mcu_wr), .snd_wr(snd_wr), .mcu_dout(mcu_dout), .snd_dout(snd_dout), .sound_run(sound_run), .sub_run(),
		.mprog_req(mprog_req), .mprog_addr(mprog_addr), .mprog_ack(mprog_ack), .mprog_valid(mprog_valid),
		.sprog_req(sprog_req), .sprog_addr(sprog_addr), .sprog_ack(sprog_ack), .sprog_valid(sprog_valid),
		.drom_req(drom_req), .drom_addr(drom_addr), .drom_ack(drom_ack), .drom_valid(drom_valid),
		.aud_req(aud_req), .aud_addr(aud_addr), .aud_ack(aud_ack), .aud_valid(aud_valid),
		.mcu_req(mcu_req), .mcu_addr_m(mcu_addr_m), .mcu_ack(mcu_ack), .mcu_valid(mcu_valid),
		.c140_req(c140_req), .c140_addr(c140_addr), .c140_ack(c140_ack), .c140_valid(c140_valid),
		.bank0_data(bank0_data), .bank1_data(bank1_data),
		.wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr), .wram_din(wram_din), .wram_dsn(wram_dsn),
		.wram_ack(wram_ack), .wram_valid(wram_valid),
		.clut_we(clut_we), .clut_addr(clut_addr), .clut_data(clut_data), .nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data),
		.overrun(overrun), .overrun_src(overrun_src), .line_busy_max(line_busy_max),
		.mcu_tap(), .mcu_sync(), .mcu_cen(mcu_cen), .mcu_din());

	// the memory
	wire [21:0] sd_addr0, sd_addr1, sd_addr2, sd_addr3, prog_addr;
	wire [3:0]  sd_push, sd_full, sd_valid_t, sd_push_we;
	wire [63:0] sd_push_din;
	wire [7:0]  sd_push_dsn;
	wire [63:0] sd_data0, sd_data1, sd_data2, sd_data3;
	wire [1:0]  prog_ba, prog_dsn;
	wire [15:0] prog_din;
	wire        prog_req_t, prog_ack_t;
	ns2_mem #(.WRAM_SD(WRAM_SD)) u_mem (.clk(clk), .rst(rst), .board(board), .mh_wiring(mh_wiring), .lw_wiring(lw_wiring), .drom_empty(2'b00),
		.dl(dl), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
		.clut_we(clut_we), .clut_addr(clut_addr), .clut_data(clut_data), .nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data),
		.class_we(class_we), .class_addr(class_addr), .class_data(class_data),
		.tile_req(ft_req), .tile_addr(ft_addr), .tile_ack(ft_ack), .tile_valid(ft_valid), .tile_data(ft_data),
		.tmask_req(fm_req), .tmask_addr(fm_addr), .tmask_ack(fm_ack), .tmask_valid(fm_valid), .tmask_data(fm_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.mprog_req(mprog_req), .mprog_addr({2'b00, mprog_addr}), .mprog_ack(mprog_ack), .mprog_valid(mprog_valid),
		.sprog_req(sprog_req), .sprog_addr({2'b00, sprog_addr}), .sprog_ack(sprog_ack), .sprog_valid(sprog_valid),
		.drom_req(drom_req), .drom_addr({2'b00, drom_addr}), .drom_ack(drom_ack), .drom_valid(drom_valid),
		.aud_req(aud_req), .aud_addr({2'b00, aud_addr}), .aud_ack(aud_ack), .aud_valid(aud_valid),
		.mcu_req(mcu_req), .mcu_addr({2'b00, mcu_addr_m}), .mcu_ack(mcu_ack), .mcu_valid(mcu_valid),
		.c140_req(c140_req), .c140_addr({2'b00, c140_addr}), .c140_ack(c140_ack), .c140_valid(c140_valid),
		.bank0_data(bank0_data), .bank1_data(bank1_data),
		.wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr), .wram_din(wram_din), .wram_dsn(wram_dsn),
		.wram_ack(wram_ack), .wram_valid(wram_valid),
		.sd_addr0(sd_addr0), .sd_addr1(sd_addr1), .sd_addr2(sd_addr2), .sd_addr3(sd_addr3),
		.sd_push(sd_push), .sd_full(sd_full), .sd_valid_t(sd_valid_t),
		.sd_push_we(sd_push_we), .sd_push_din(sd_push_din), .sd_push_dsn(sd_push_dsn),
		.sd_data0(sd_data0), .sd_data1(sd_data1), .sd_data2(sd_data2), .sd_data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t));

	ns2_tile_filter u_filter (.clk(clk), .rst(rst), .tile_fl2(tile_fl2),
		.class_we(class_we), .class_addr(class_addr), .class_data(class_data),
		.t_req(tile_req), .t_addr(tile_addr), .t_ack(tile_ack), .t_valid(tile_valid), .t_data(tile_data),
		.m_req(tmask_req), .m_addr(tmask_addr), .m_ack(tmask_ack), .m_valid(tmask_valid), .m_data(tmask_data),
		.dt_req(ft_req), .dt_addr(ft_addr), .dt_ack(ft_ack), .dt_valid(ft_valid), .dt_data(ft_data),
		.dm_req(fm_req), .dm_addr(fm_addr), .dm_ack(fm_ack), .dm_valid(fm_valid), .dm_data(fm_data),
		.n_t(n_t), .n_t_miss(n_t_miss), .n_m(n_m), .n_m_miss(n_m_miss));

	wire [15:0] dq_q, sdram_din, dq;
	wire        dq_oe, dqml, dqmh, nwe, ncas, nras, ncs, cke;
	wire [12:0] a;
	wire [1:0]  ba;
	assign dq = dq_oe ? dq_q : sdram_din;
	ns2_sdram #(.WEN(WRAM_SD ? 4'b0010 : 4'b0000), .CL(SD_CL), .XRC(SD_XRC)) u_sd (.clk(clk), .clk_sd(clk_sd), .rst(rst), .init(sd_init), .rfsh(rfsh),
		.addr0(sd_addr0), .addr1(sd_addr1), .addr2(sd_addr2), .addr3(sd_addr3), .push(sd_push), .req_full(sd_full), .valid_t(sd_valid_t),
		.push_we(sd_push_we), .push_din(sd_push_din), .push_dsn(sd_push_dsn),
		.data0(sd_data0), .data1(sd_data1), .data2(sd_data2), .data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_en(dl),
		.prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t),
		.SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(ba), .SDRAM_nWE(nwe),
		.SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nCS(ncs), .SDRAM_CKE(cke), .sdram_din(sdram_din));
	sdram_model_burst #(.TCK_NS(10.1725)) u_model (.SDRAM_CLK(clk_sd), .SDRAM_A(a), .SDRAM_BA(ba), .DQ_IN(sdram_din), .DQ_Q(dq_q), .DQ_OE(dq_oe),
		.SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs), .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras),
		.SDRAM_nWE(nwe), .SDRAM_CKE(cke), .violations(violations));
endmodule
