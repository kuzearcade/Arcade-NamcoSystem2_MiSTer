// M4's first fit (docs/PLAN.md Appendix F): the standard bitstream's core --
// the board with its ROMs in the SDRAM (ns2_board ROMS = 1), ns2_mem, the
// tile filter and ns2_sdram -- with every output on a (virtual) pin, so that
// Quartus keeps it all and reports the ALMs, M10K and timing it needs. No
// PLL, no MiSTer framework (their share is Appendix F's 107 blocks). NS2-13.
module core_top (
	input             clk,            // 49.152 MHz
	input             clk_sd,         // 98.304 MHz
	input             rst,
	input             reset,
	input             dl,
	input             dl_wr,
	input      [24:0] dl_addr,
	input      [15:0] dl_data,
	output            dl_wait,
	input      [2:0]  board,
	input             mcu_c68, tile_fl2, spr_fl, mh_wiring, lw_wiring,
	input      [135:0] key_table,
	input      [1:0]  key_mode,
	input      [7:0]  mcub, mcuc, mcuh, dsw,
	input      [31:0] dials,
	input      [63:0] analog,
	output     [7:0]  red, green, blue,
	output     [8:0]  hcnt, vcnt,
	output            out_valid,
	output signed [15:0] ym_left, ym_right, c140_left, c140_right,
	inout      [15:0] SDRAM_DQ,
	output     [12:0] SDRAM_A,
	output            SDRAM_DQML, SDRAM_DQMH,
	output     [1:0]  SDRAM_BA,
	output            SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS, SDRAM_CKE
);
	wire        tile_req, tmask_req, roz_req, c169_req, c169m_req, spr_req;
	wire [18:0] tile_addr, tmask_addr, roz_addr, c169m_addr;
	wire [20:0] c169_addr;
	wire [19:0] spr_addr;
	wire        tile_ack, tmask_ack, roz_ack, c169_ack, c169m_ack, spr_ack;
	wire        tile_valid, tmask_valid, roz_valid, c169_valid, c169m_valid, spr_valid;
	wire [63:0] tile_data, roz_data, c169_data, spr_data;
	wire [7:0]  tmask_data, c169m_data;
	wire        mprog_req, sprog_req, drom_req, aud_req, mcu_req, c140_req;
	wire [14:0] mprog_addr, sprog_addr, aud_addr;
	wire [17:0] drom_addr, c140_addr;
	wire [12:0] mcu_addr_m;
	wire        mprog_ack, sprog_ack, drom_ack, aud_ack, mcu_ack, c140_ack;
	wire        mprog_valid, sprog_valid, drom_valid, aud_valid, mcu_valid, c140_valid;
	wire [63:0] bank0_data, bank1_data;
	wire        clut_we, nv_we, class_we;
	wire [7:0]  clut_addr, clut_data, nv_data;
	wire [12:0] nv_addr;
	wire [15:0] class_addr;
	wire [1:0]  class_data;
	wire        ft_req, ft_ack, ft_valid, fm_req, fm_ack, fm_valid;
	wire [18:0] ft_addr;
	wire [15:0] fm_addr;
	wire [63:0] ft_data, fm_data;

	ns2_board #(.ROMS(1), .HAS_C45(1), .HAS_C169(0), .HAS_C355(0)) u_board (
		.clk(clk), .reset(reset || dl), .board(board), .mcu_c68(mcu_c68), .tile_fl2(tile_fl2), .spr_fl(spr_fl),
		.key_table(key_table), .key_mode(key_mode),
		.mcub(mcub), .mcuc(mcuc), .mcuh(mcuh), .dsw(dsw), .dials(dials), .analog(analog),
		.red(red), .green(green), .blue(blue), .out_x(), .out_y(), .out_valid(out_valid), .hcnt(hcnt), .vcnt(vcnt),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_valid(tile_valid), .tile_data(tile_data),
		.tmask_req(tmask_req), .tmask_addr(tmask_addr), .tmask_ack(tmask_ack), .tmask_valid(tmask_valid), .tmask_data(tmask_data),
		.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_valid(roz_valid), .roz_data(roz_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_valid(spr_valid), .spr_data(spr_data),
		.c169_req(c169_req), .c169_addr(c169_addr), .c169_ack(c169_ack), .c169_valid(c169_valid), .c169_data(c169_data),
		.c169m_req(c169m_req), .c169m_addr(c169m_addr), .c169m_ack(c169m_ack), .c169m_valid(c169m_valid), .c169m_data(c169m_data),
		.ym_left(ym_left), .ym_right(ym_right), .c140_left(c140_left), .c140_right(c140_right), .c140_raw_l(), .c140_raw_r(), .c140_sample(),
		.m_as(), .s_as(), .m_addr(), .s_addr(), .m_rnw(), .s_rnw(), .m_wdata(), .s_wdata(), .m_ds(), .s_ds(),
		.m_rdata(), .s_rdata(), .m_dtack(), .s_dtack(),
		.mcu_addr(), .snd_addr(), .mcu_wr(), .snd_wr(), .mcu_dout(), .snd_dout(), .sound_run(), .sub_run(),
		.mprog_req(mprog_req), .mprog_addr(mprog_addr), .mprog_ack(mprog_ack), .mprog_valid(mprog_valid),
		.sprog_req(sprog_req), .sprog_addr(sprog_addr), .sprog_ack(sprog_ack), .sprog_valid(sprog_valid),
		.drom_req(drom_req), .drom_addr(drom_addr), .drom_ack(drom_ack), .drom_valid(drom_valid),
		.aud_req(aud_req), .aud_addr(aud_addr), .aud_ack(aud_ack), .aud_valid(aud_valid),
		.mcu_req(mcu_req), .mcu_addr_m(mcu_addr_m), .mcu_ack(mcu_ack), .mcu_valid(mcu_valid),
		.c140_req(c140_req), .c140_addr(c140_addr), .c140_ack(c140_ack), .c140_valid(c140_valid),
		.bank0_data(bank0_data), .bank1_data(bank1_data),
		.clut_we(clut_we), .clut_addr(clut_addr), .clut_data(clut_data), .nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data),
		.overrun(), .overrun_src(), .line_busy_max(),
		.mcu_tap(), .mcu_sync(), .mcu_cen(), .mcu_din());

	ns2_tile_filter u_filter (.clk(clk), .rst(rst), .tile_fl2(tile_fl2),
		.class_we(class_we), .class_addr(class_addr), .class_data(class_data),
		.t_req(tile_req), .t_addr(tile_addr), .t_ack(tile_ack), .t_valid(tile_valid), .t_data(tile_data),
		.m_req(tmask_req), .m_addr(tmask_addr), .m_ack(tmask_ack), .m_valid(tmask_valid), .m_data(tmask_data),
		.dt_req(ft_req), .dt_addr(ft_addr), .dt_ack(ft_ack), .dt_valid(ft_valid), .dt_data(ft_data),
		.dm_req(fm_req), .dm_addr(fm_addr), .dm_ack(fm_ack), .dm_valid(fm_valid), .dm_data(fm_data),
		.n_t(), .n_t_miss(), .n_m(), .n_m_miss());

	wire [21:0] sd_addr0, sd_addr1, sd_addr2, sd_addr3, prog_addr;
	wire [3:0]  sd_push, sd_full, sd_valid_t;
	wire [63:0] sd_data0, sd_data1, sd_data2, sd_data3;
	wire [1:0]  prog_ba, prog_dsn;
	wire [15:0] prog_din;
	wire        prog_req_t, prog_ack_t;
	ns2_mem u_mem (.clk(clk), .rst(rst), .board(board), .mh_wiring(mh_wiring), .lw_wiring(lw_wiring), .drom_empty(2'b00),
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
		.sd_addr0(sd_addr0), .sd_addr1(sd_addr1), .sd_addr2(sd_addr2), .sd_addr3(sd_addr3),
		.sd_push(sd_push), .sd_full(sd_full), .sd_valid_t(sd_valid_t),
		.sd_data0(sd_data0), .sd_data1(sd_data1), .sd_data2(sd_data2), .sd_data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t));

	ns2_sdram u_sd (.clk(clk), .clk_sd(clk_sd), .rst(rst), .init(), .rfsh(hcnt >= 9'd300),
		.addr0(sd_addr0), .addr1(sd_addr1), .addr2(sd_addr2), .addr3(sd_addr3), .push(sd_push), .req_full(sd_full), .valid_t(sd_valid_t),
		.data0(sd_data0), .data1(sd_data1), .data2(sd_data2), .data3(sd_data3),
		.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_en(dl),
		.prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE));
endmodule
