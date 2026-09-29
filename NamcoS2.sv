// Arcade-NamcoSystem2_MiSTer -- MiSTer top level, the standard bitstream
// (docs/PLAN.md 2.4): the standard boards (sprites A + ROZ A) and Final Lap
// / Four Trax (sprites A + the C45 road), with the C65 or the C68.
//
// Derived from Arcade-GingaNin_MiSTer's GingaNin.sv (docs/provenance.md):
// the OSD layout, keyboard map, download/reset sequencing and video chain
// are GingaNin's. What differs:
//
//   * The board: ns2_board with its ROMs in the SDRAM (ROMS = 1) behind
//     ns2_mem, ns2_tile_filter and ns2_sdram (jtframe_sdram64 at 98.304 MHz).
//     The download is 16-bit (hps_io WIDE).
//   * The set's configuration (board code, MCU, wirings, the key custom's
//     table) is a 32-byte block of the image at 0x00D6000
//     (tools/ns2_romdata.py config_block), latched here as it streams past.
//     The board stays in reset until it has arrived.
//   * High scores are the games' own EEPROM (D6): ioctl index 4 loads the
//     .nvm over the default the image carries, and an upload saves it.
//   * The raster is 384 x 264 at 6.144 MHz (clk_sys / 8), 288 x 224 visible.
//   * Not yet (M5): savestates, cheats, autofire, pause.
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1; // signed PCM
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
// The bitstream (docs/PLAN.md 2.4): NS2_MH (NamcoS2_MH.qsf) is Metal Hawk's,
// the C169 and no standard ROZ or C45 road; otherwise the standard one.
// NS2_SZ (Suzuka 8 Hours) and NS2_LW (Lucky & Wild) keep the 68000s' work
// RAMs and the C139's RAM in the SDRAM (WRAM_SD) to fit their block RAM;
// NS2_LW also narrows the CRT V-Size to one step each way (its ring).
`ifdef NS2_MH
localparam HAS_SPRA = 1, HAS_ROZ = 0, HAS_C45 = 0, HAS_C169 = 1, HAS_C355 = 0, WRAM_SD = 0, VSIZE_MAX = 4;
localparam CORE_NAME = "NamcoS2_MH";
localparam VSIZE_OSD = "0,+1,+2,+3,+4,-4,-3,-2,-1";
`elsif NS2_SZ
localparam HAS_SPRA = 0, HAS_ROZ = 0, HAS_C45 = 1, HAS_C169 = 0, HAS_C355 = 1, WRAM_SD = 1, VSIZE_MAX = 4;
localparam CORE_NAME = "NamcoS2_SZ";
localparam VSIZE_OSD = "0,+1,+2,+3,+4,-4,-3,-2,-1";
`elsif NS2_LW
localparam HAS_SPRA = 0, HAS_ROZ = 0, HAS_C45 = 1, HAS_C169 = 1, HAS_C355 = 1, WRAM_SD = 1, VSIZE_MAX = 1;
localparam CORE_NAME = "NamcoS2_LW";
localparam VSIZE_OSD = "0,+1,-1";
`elsif NS2_SG
localparam HAS_SPRA = 0, HAS_ROZ = 0, HAS_C45 = 0, HAS_C169 = 0, HAS_C355 = 1, WRAM_SD = 0, VSIZE_MAX = 4;
localparam CORE_NAME = "NamcoS2_SG";
localparam VSIZE_OSD = "0,+1,+2,+3,+4,-4,-3,-2,-1";
`else
localparam HAS_SPRA = 1, HAS_ROZ = 1, HAS_C45 = 1, HAS_C169 = 0, HAS_C355 = 0, WRAM_SD = 0, VSIZE_MAX = 4;
localparam CORE_NAME = "NamcoS2";
localparam VSIZE_OSD = "0,+1,+2,+3,+4,-4,-3,-2,-1";
`endif
// (VSIZE_OSD: crt_chain's V-Size list, "0,+1..+MAX,-MAX..-1", each its own
// literal: strings of two lengths under ?: would pad one with NULs)
localparam CONF_STR = {
	CORE_NAME, ";;",
	"-;",
	"HBO[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"H0O[9:8],Orientation,Horz,Vert 90,Vert 270;",
	// 180 degrees in the core, on every video path (ns2_flipbuf); a ROT180
	// set (MAME's Bubble Trouble) starts turned, and this turns it back
	"O[17],Flip screen,Off,On;",
	"O[18],Gun crosshair,On,Off;",
	"P3,CRT Adjust;",
	"P3O[101],CRT Adjust,Off,On;",
	"P3O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[107:104],CRT V-Size,", VSIZE_OSD, ";",
	"P3O[108],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"DIP;",
	"-;",
	// the games keep their settings and scores in the EEPROM (the .nvm)
	"R[30],Save NVRAM;",
	"-;",
	"R[0],Reset;",
	// positionally matched against the <buttons> list the .mra writes
	"J1,Button 1,Button 2,Button 3,Start,Coin,Service,Button 4,Button 5;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire         direct_video;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] stick_0, stick_1, rstick_0;
wire  [24:0] ps2_mouse;

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr_full;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;
wire  [15:0] ioctl_index;
wire         ioctl_upload, ioctl_upload_req;
wire  [15:0] ioctl_din;
wire  [21:0] vm_gamma_bus;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(vm_gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	// [11] hides Aspect ratio and Scandoubler Fx under direct video;
	// [0] hides Orientation under direct video
	.status_menumask({4'd0, direct_video, 10'd0, direct_video}),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(stick_0),
	.joystick_l_analog_1(stick_1),
	.joystick_r_analog_0(rstick_0),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),

	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;     // 49.152 MHz: the board
wire clk_sd;      // 98.304 MHz: the SDRAM controller, CLK_VIDEO
wire clk_sdo;     // 98.304 MHz, 171 degrees: the SDRAM chip (rtl/pll_ns2.v)
wire pll_locked;
pll_ns2 pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sd),
	.outclk_2(clk_sdo),
	.locked(pll_locked)
);

altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
	.power_up_high("OFF"), .width(1)
) sdram_clk_ddr (
	.datain_h(1'b1), .datain_l(1'b0), .outclock(clk_sdo), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
);

// Power-on reset for the SDRAM side (ns2_sdram, ns2_mem, the tile filter):
// they ARE the download and must work through the game's reset.
reg [3:0] por_cnt = 4'd0;
reg       por_rst = 1'b1;
always @(posedge clk_sys) begin
	if (~pll_locked) begin
		por_cnt <= 4'd0;
		por_rst <= 1'b1;
	end else if (por_rst) begin
		if (por_cnt == 4'd15) por_rst <= 1'b0;
		else por_cnt <= por_cnt + 4'd1;
	end
end

// The game's reset: held for the whole download, then for a tail restarted
// by every ioctl session, until the <switches> have arrived (MS1-53) and
// until a set's configuration has. A change of the DIPs after the first
// <switches> does not reset: the games keep their test-mode settings (the
// FLIP among them) in the EEPROM, and write them as the test switch goes off
// (NS2-22); a reset there would lose them. "Reset to apply" still resets.
reg         sw_seen  = 1'b0;
wire        dl_hold  = ioctl_download & ~(ioctl_index == 16'd254 & sw_seen);
reg [23:0] dl_tail = {24{1'b1}};
always @(posedge clk_sys) begin
	if (dl_hold)                     dl_tail <= 24'd0;
	else if (dl_tail != {24{1'b1}})  dl_tail <= dl_tail + 1'd1;
end
wire dl_settling = (dl_tail != {24{1'b1}});

reg  [27:0] sw_tmo   = 28'd0;
always @(posedge clk_sys) begin
	if (ioctl_download) begin
		sw_tmo <= 28'd0;
		if (ioctl_wr && ioctl_index == 16'd254) sw_seen <= 1'b1;
	end else if (~&sw_tmo) sw_tmo <= sw_tmo + 1'd1;
end
wire wait_switches = ~sw_seen & ~&sw_tmo;

// ------------------------------------------------------------------
// The set's configuration: image 0x00D6000-0x00D602F (config_block)
// ------------------------------------------------------------------
wire       dl_rom = ioctl_download && ioctl_index == 16'd0;
reg [7:0]  cfg [0:63];
reg        cfg_ok = 1'b0;
integer    ci;
initial for (ci = 0; ci < 64; ci = ci + 1) cfg[ci] = 8'h00;
always @(posedge clk_sys) begin
	if (dl_rom && ioctl_wr && ioctl_addr[24:6] == 19'h03580) begin
		cfg[{ioctl_addr[5:1], 1'b0}] <= ioctl_dout[7:0];
		cfg[{ioctl_addr[5:1], 1'b1}] <= ioctl_dout[15:8];
	end
end
always @(posedge clk_sys) if (!ioctl_download) cfg_ok <= cfg[0] == "N" && cfg[1] == "2";
wire [2:0]   cfg_board  = cfg[2][2:0];
wire         cfg_c68    = cfg[2][3];
wire         cfg_fl2    = cfg[2][4];
wire         cfg_sprfl  = cfg[2][5];
wire         cfg_mh     = cfg[2][6];
wire         cfg_lw     = cfg[2][7];
wire [1:0]   cfg_kmode  = cfg[3][1:0];
// MAME's power-on analog and dial values (M5 maps the controls onto them)
wire [63:0]  cfg_analog = {cfg[28], cfg[27], cfg[26], cfg[25], cfg[24], cfg[23], cfg[22], cfg[21]};
wire [31:0]  cfg_dials  = {cfg[32], cfg[31], cfg[30], cfg[29]};
wire [135:0] cfg_ktable = {cfg[20], cfg[19], cfg[18], cfg[17], cfg[16], cfg[15], cfg[14], cfg[13], cfg[12],
                           cfg[11], cfg[10], cfg[9], cfg[8], cfg[7], cfg[6], cfg[5], cfg[4]};

wire reset = RESET | status[0] | buttons[1] | dl_hold | dl_settling | wait_switches | ~pll_locked | ~cfg_ok;

// ------------------------------------------------------------------
// The .mra <switches> block, ioctl index 254, 16-bit words. Byte 0 is
// MAME's DSW port (the MCU's $2000; bit 7 the test switch).
// ------------------------------------------------------------------
reg [7:0] dip_sw [0:7];
integer dip_i;
initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3]) begin
		dip_sw[{ioctl_addr[2:1], 1'b0}] <= ioctl_dout[7:0];
		dip_sw[{ioctl_addr[2:1], 1'b1}] <= ioctl_dout[15:8];
	end
end

// ------------------------------------------------------------------
// Keyboard: MAME's default bindings, always live, ORed with the pads.
//   P1: arrows, Left Ctrl = B1, Left Alt = B2, Space = B3, Left Shift = B4, Z = B5
//   P2: R/F/D/G, A = B1, S = B2, Q = B3
//   Coin 1 = 5, Coin 2 = 6, Start 1/2 = 1/2, Service 1 = 9
// ------------------------------------------------------------------
reg [8:0] kb_p1 = 9'd0;                 // [0]=R [1]=L [2]=D [3]=U [4]=B1 [5]=B2 [6]=B3 [7]=B4 [8]=B5
reg [6:0] kb_p2 = 7'd0;
reg kb_start1 = 1'b0, kb_start2 = 1'b0;
reg kb_coin1 = 1'b0, kb_coin2 = 1'b0, kb_service = 1'b0;
reg kb_toggle_d = 1'b0;
always @(posedge clk_sys) begin
	kb_toggle_d <= ps2_key[10];
	if (kb_toggle_d != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h175: kb_p1[3] <= ps2_key[9];
			9'h172: kb_p1[2] <= ps2_key[9];
			9'h16B: kb_p1[1] <= ps2_key[9];
			9'h174: kb_p1[0] <= ps2_key[9];
			9'h014: kb_p1[4] <= ps2_key[9];
			9'h011: kb_p1[5] <= ps2_key[9];
			9'h029: kb_p1[6] <= ps2_key[9];
			9'h012: kb_p1[7] <= ps2_key[9];
			9'h01A: kb_p1[8] <= ps2_key[9];
			9'h02D: kb_p2[3] <= ps2_key[9];
			9'h02B: kb_p2[2] <= ps2_key[9];
			9'h023: kb_p2[1] <= ps2_key[9];
			9'h034: kb_p2[0] <= ps2_key[9];
			9'h01C: kb_p2[4] <= ps2_key[9];
			9'h01B: kb_p2[5] <= ps2_key[9];
			9'h015: kb_p2[6] <= ps2_key[9];
			9'h016: kb_start1 <= ps2_key[9];
			9'h01E: kb_start2 <= ps2_key[9];
			9'h02E: kb_coin1  <= ps2_key[9];
			9'h036: kb_coin2  <= ps2_key[9];
			9'h046: kb_service <= ps2_key[9];
			default: ;
		endcase
	end
end

// ------------------------------------------------------------------
// Inputs: MAME's ports (namcos2.cpp NAMCOS2_MCU_PORT_*_DEFAULT), active low.
//   MCUB: 0 P2 left, 1 P1 left, 2 P2 down, 3 P1 down, 4 P2 up, 5 P1 up,
//         6 start 2, 7 start 1
//   MCUC: 4 coin 2, 5 coin 1, 6 service 2, 7 service 1 (0-3 unused)
//   MCUH: 0 P2 B3, 1 P1 B3, 2 P2 B2, 3 P1 B2, 4 P2 B1, 5 P1 B1,
//         6 P2 right, 7 P1 right
// MiSTer's pad bits: 0 right, 1 left, 2 down, 3 up, then the <buttons>
// list: 4 B1, 5 B2, 6 B3, 7 Start, 8 Coin, 9 Service, 10 B4, 11 B5.
// The sets with a wheel and pedals, light guns or Metal Hawk's stick map
// the analog sticks and the mouse onto AN0-AN7 (ns2_controls, the set's
// control mode in config byte 33); the others keep MAME's power-on values.
// ------------------------------------------------------------------
wire [8:0] p1 = {joystick_0[11:10], joystick_0[6:0]} | kb_p1;
wire [8:0] p2 = {joystick_1[11:10], joystick_1[6:0]} | {2'b00, kb_p2};
wire p1_start = joystick_0[7] | kb_start1, p2_start = joystick_1[7] | kb_start2;
wire p1_coin  = joystick_0[8] | kb_coin1,  p2_coin  = joystick_1[8] | kb_coin2;
wire p1_svc   = joystick_0[9] | kb_service, p2_svc  = joystick_1[9];
wire [7:0]  in_mcub, in_mcuc, in_mcuh;
wire [63:0] in_analog;
wire        guns_on, gun2_on;
wire [8:0]  gun1_x, gun2_x;
wire [7:0]  gun1_y, gun2_y;

// ------------------------------------------------------------------
// The NVRAM (the master's EEPROM, 8 KB): the image's default arrives with
// the ROM (ns2_mem), then ioctl index 4 loads the .nvm over it; an upload
// of index 4 saves it (Save NVRAM, or opening the OSD after the game has
// written the EEPROM).
// ------------------------------------------------------------------
wire        mem_nv_we;
wire [12:0] mem_nv_addr;
wire  [7:0] mem_nv_data;
wire  [7:0] nv_q;
wire        nv_cpu_we;

wire dl_nv = ioctl_download && ioctl_index == 16'd4;
reg        nvl_hi = 1'b0;           // the word's second byte, a clock after the first
reg [12:0] nvl_addr;
reg  [7:0] nvl_data;
reg        nvl_we;
always @(posedge clk_sys) begin
	nvl_we <= 1'b0;
	nvl_hi <= 1'b0;
	if (dl_nv && ioctl_wr && !ioctl_addr[24:13]) begin
		nvl_we <= 1'b1; nvl_addr <= {ioctl_addr[12:1], 1'b0}; nvl_data <= ioctl_dout[7:0]; nvl_hi <= 1'b1;
	end else if (nvl_hi) begin
		nvl_we <= 1'b1; nvl_addr <= {nvl_addr[12:1], 1'b1}; nvl_data <= ioctl_dout[15:8];
	end
end

// the save: both bytes of the word at ioctl_addr, read on alternate clocks
reg        nvs_ph = 1'b0, nvs_ph_d = 1'b0;
reg  [7:0] nvs_lo, nvs_hi;
always @(posedge clk_sys) begin
	nvs_ph <= ~nvs_ph; nvs_ph_d <= nvs_ph;
	if (nvs_ph_d) nvs_hi <= nv_q; else nvs_lo <= nv_q;
end
assign ioctl_din = {nvs_hi, nvs_lo};

wire        nv_we   = mem_nv_we | nvl_we;
wire [12:0] nv_addr = mem_nv_we ? mem_nv_addr : nvl_we ? nvl_addr : {ioctl_addr[12:1], nvs_ph};
wire  [7:0] nv_data = mem_nv_we ? mem_nv_data : nvl_data;

// dirty: the game wrote the EEPROM since the last load or save
reg nv_dirty = 1'b0, osd_d = 1'b0, save_d = 1'b0, up_req = 1'b0;
always @(posedge clk_sys) begin
	osd_d <= OSD_STATUS; save_d <= status[30];
	if (dl_nv || ioctl_upload) nv_dirty <= 1'b0;
	else if (nv_cpu_we && !reset) nv_dirty <= 1'b1;
	up_req <= (status[30] && !save_d) || (OSD_STATUS && !osd_d && nv_dirty);
end
assign ioctl_upload_req = up_req;

// ------------------------------------------------------------------
// The board, its SDRAM side
// ------------------------------------------------------------------
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
wire        clut_we, class_we;
wire [7:0]  clut_addr, clut_data;
wire [15:0] class_addr;
wire [1:0]  class_data;
wire        ft_req, ft_ack, ft_valid, fm_req, fm_ack, fm_valid;
wire [18:0] ft_addr;
wire [15:0] fm_addr;
wire [63:0] ft_data, fm_data;
wire [7:0]  core_r, core_g, core_b;
wire [8:0]  hcnt, vcnt;
wire signed [15:0] ym_left, ym_right, c140_left, c140_right;

wire [2:0]  wram_req, wram_we, wram_ack, wram_valid;
wire [44:0] wram_addr;
wire [47:0] wram_din;
wire [5:0]  wram_dsn;

ns2_board #(.ROMS(1), .HAS_SPRA(HAS_SPRA), .HAS_ROZ(HAS_ROZ), .HAS_C45(HAS_C45), .HAS_C169(HAS_C169), .HAS_C355(HAS_C355),
            .WRAM_SD(WRAM_SD)) board (
	.clk(clk_sys), .reset(reset), .board(cfg_board), .mcu_c68(cfg_c68), .tile_fl2(cfg_fl2), .spr_fl(cfg_sprfl),
	.key_table(cfg_ktable), .key_mode(cfg_kmode),
	.mcub(in_mcub), .mcuc(in_mcuc), .mcuh(in_mcuh), .dsw(dip_sw[0]), .dials(cfg_dials), .analog(in_analog), .dbg_stall(1'b0), .dbg_holds(),
	.red(core_r), .green(core_g), .blue(core_b), .ce_pix(ce_pix), .out_x(), .out_y(), .out_valid(), .hcnt(hcnt), .vcnt(vcnt),
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
	.wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr), .wram_din(wram_din), .wram_dsn(wram_dsn),
	.wram_ack(wram_ack), .wram_valid(wram_valid),
	.clut_we(clut_we), .clut_addr(clut_addr), .clut_data(clut_data),
	.nv_we(nv_we), .nv_addr(nv_addr), .nv_data(nv_data), .nv_q(nv_q), .nv_cpu_we(nv_cpu_we),
	.overrun(), .overrun_src(), .line_busy_max(),
	.mcu_tap(), .mcu_sync(), .mcu_cen(), .mcu_din());

ns2_tile_filter tile_filter (.clk(clk_sys), .rst(por_rst), .tile_fl2(cfg_fl2),
	.class_we(class_we), .class_addr(class_addr), .class_data(class_data),
	.t_req(tile_req), .t_addr(tile_addr), .t_ack(tile_ack), .t_valid(tile_valid), .t_data(tile_data),
	.m_req(tmask_req), .m_addr(tmask_addr), .m_ack(tmask_ack), .m_valid(tmask_valid), .m_data(tmask_data),
	.dt_req(ft_req), .dt_addr(ft_addr), .dt_ack(ft_ack), .dt_valid(ft_valid), .dt_data(ft_data),
	.dm_req(fm_req), .dm_addr(fm_addr), .dm_ack(fm_ack), .dm_valid(fm_valid), .dm_data(fm_data),
	.n_t(), .n_t_miss(), .n_m(), .n_m_miss());

wire [21:0] sd_addr0, sd_addr1, sd_addr2, sd_addr3, prog_addr;
wire [3:0]  sd_push, sd_full, sd_valid_t, sd_push_we;
wire [63:0] sd_push_din;
wire [7:0]  sd_push_dsn;
wire [63:0] sd_data0, sd_data1, sd_data2, sd_data3;
wire [1:0]  prog_ba, prog_dsn;
wire [15:0] prog_din;
wire        prog_req_t, prog_ack_t;
wire        dl_wait;
assign ioctl_wait = dl_rom & dl_wait;

ns2_mem #(.WRAM_SD(WRAM_SD)) mem (.clk(clk_sys), .rst(por_rst), .board(cfg_board), .mh_wiring(cfg_mh), .lw_wiring(cfg_lw), .drom_empty(cfg[3][5:4]),
	.dl(dl_rom), .dl_wr(dl_rom & ioctl_wr), .dl_addr(ioctl_addr), .dl_data(ioctl_dout), .dl_wait(dl_wait),
	.clut_we(clut_we), .clut_addr(clut_addr), .clut_data(clut_data),
	.nv_we(mem_nv_we), .nv_addr(mem_nv_addr), .nv_data(mem_nv_data),
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
	.wram_req(wram_req), .wram_we(wram_we), .wram_addr(wram_addr), .wram_din(wram_din), .wram_dsn(wram_dsn),
	.wram_ack(wram_ack), .wram_valid(wram_valid),
	.bank0_data(bank0_data), .bank1_data(bank1_data),
	.sd_push_we(sd_push_we), .sd_push_din(sd_push_din), .sd_push_dsn(sd_push_dsn),
	.sd_addr0(sd_addr0), .sd_addr1(sd_addr1), .sd_addr2(sd_addr2), .sd_addr3(sd_addr3),
	.sd_push(sd_push), .sd_full(sd_full), .sd_valid_t(sd_valid_t),
	.sd_data0(sd_data0), .sd_data1(sd_data1), .sd_data2(sd_data2), .sd_data3(sd_data3),
	.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t));

// Refresh (jtframe_sdram64's rfsh: RFSHCNT refreshes on each rise): in the
// horizontal blank while the board runs, where it takes nothing from a line's
// fetches. While the board is held in reset (the download, its settling, the
// DIP wait, an OSD reset) its timing stops, so a free-running count of the
// same line period (3072 clocks) takes over: the chip is refreshed through
// all of it, or the rows written early in a download decay before the game
// starts (NS2-19).
reg  [11:0] rf_cnt = 12'd0;
reg         sd_rfsh = 1'b0;
always @(posedge clk_sys) begin
	rf_cnt  <= rf_cnt == 12'd3071 ? 12'd0 : rf_cnt + 12'd1;
	sd_rfsh <= reset ? rf_cnt >= 12'd2400 : hcnt >= 9'd300;
end
ns2_sdram #(.WEN(WRAM_SD ? 4'b0010 : 4'b0000)) sdram (.clk(clk_sys), .clk_sd(clk_sd), .rst(por_rst), .init(), .rfsh(sd_rfsh),
	.addr0(sd_addr0), .addr1(sd_addr1), .addr2(sd_addr2), .addr3(sd_addr3), .push(sd_push), .req_full(sd_full), .valid_t(sd_valid_t),
	.push_we(sd_push_we), .push_din(sd_push_din), .push_dsn(sd_push_dsn),
	.data0(sd_data0), .data1(sd_data1), .data2(sd_data2), .data3(sd_data3),
	.prog_addr(prog_addr), .prog_ba(prog_ba), .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_en(dl_rom),
	.prog_req_t(prog_req_t), .prog_ack_t(prog_ack_t),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE));

// ------------------------------------------------------------------
// Audio: MAME's routes (namcos2.cpp configure_c140 / the YM2151), both
// stereo: the C140 at 0.75, the YM2151 at 0.80.
// ------------------------------------------------------------------
// (the products at 25 bits: a 16-bit sample times 205 needs 24)
reg signed [24:0] ym_pl, ym_pr, c_pl, c_pr;
reg signed [17:0] mix_l, mix_r;
reg signed [15:0] aud_l, aud_r;
function signed [15:0] sat(input signed [17:0] v);
	sat = v > 18'sd32767 ? 16'sh7fff : v < -18'sd32768 ? -16'sh8000 : v[15:0];
endfunction
always @(posedge clk_sys) begin
	ym_pl <= ym_left * 25'sd205;   ym_pr <= ym_right * 25'sd205;
	c_pl  <= c140_left * 25'sd192; c_pr  <= c140_right * 25'sd192;
	mix_l <= 18'(ym_pl >>> 8) + 18'(c_pl >>> 8);
	mix_r <= 18'(ym_pr >>> 8) + 18'(c_pr >>> 8);
	aud_l <= sat(mix_l);
	aud_r <= sat(mix_r);
end
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

// ------------------------------------------------------------------
// Video. The board draws its raster on clk_sys, a pixel every 8 clocks
// (ce_pix); at ce_pix, red/green/blue are the pixel at hcnt/vcnt
// (ns2_video's mix: the palette read at div 4, the output at div 5).
// video_retime moves it onto CLK_VIDEO (98.304 MHz, /16): 384 pixels a
// line (6144 clocks), 264 lines, 288 x 224 visible from (0, 0), hsync at
// pixel 320 for 32, vsync 16 lines into the blank (line 240), as
// ns2_video's own syncs. crt_chain applies the analog geometry controls,
// and video_mixer drives VGA_*.
// ------------------------------------------------------------------
// Flip screen (and a ROT180 set's own turn): 180 degrees in the core
// (ns2_flipbuf, NS2-22), on every video path; with Orientation's quarter
// turns, screen_rotate turns the picture on HDMI instead
wire       flip_180 = cfg[3][6] ^ status[17];
wire  [1:0] orientation = status[9:8];
wire        no_rotate = (orientation == 2'd0) | direct_video;

// the controls (above): the guns aim at the picture as displayed
ns2_controls controls (.clk(clk_sys), .reset(reset), .vblank(vcnt >= 9'd224), .mode(cfg[33]), .flip(flip_180),
	.an_default(cfg_analog), .idle_b(cfg[34]), .idle_h(cfg[35]), .p1(p1), .p2(p2), .start1(p1_start), .start2(p2_start),
	.coin1(p1_coin), .coin2(p2_coin), .svc1(p1_svc), .svc2(p2_svc),
	.stick1(stick_0), .stick2(stick_1), .rstick1(rstick_0), .mouse(ps2_mouse),
	.mcub(in_mcub), .mcuc(in_mcuc), .mcuh(in_mcuh), .analog(in_analog),
	.guns(guns_on), .g2_on(gun2_on), .g1_x(gun1_x), .g2_x(gun2_x), .g1_y(gun1_y), .g2_y(gun2_y));

// the guns' crosshairs (OSD "Gun crosshair"): a 7-pixel cross each, white
// for player 1 and yellow for player 2 (once player 2 has aimed), over the
// board's picture
function xhair(input [8:0] x, input [8:0] y, input [8:0] gx, input [7:0] gy);
	reg [8:0] dx, dy;
	begin
		dx = x - gx; dy = y - {1'b0, gy};
		xhair = (dy == 0 && (dx < 9'd4 || dx > 9'd508)) || (dx == 0 && (dy < 9'd4 || dy > 9'd508));
	end
endfunction
wire        xh_on = guns_on && !status[18];
wire        xh1 = xh_on && xhair(hcnt, vcnt, gun1_x, gun1_y);
wire        xh2 = xh_on && gun2_on && xhair(hcnt, vcnt, gun2_x, gun2_y);
wire [23:0] core_rgb = xh1 ? 24'hffffff : xh2 ? 24'hffff00 : {core_r, core_g, core_b};

wire ce_pix;

wire        rt_ce, rt_hs, rt_vs, rt_hb, rt_vb, rt_vb_hs;
wire [23:0] rt_rgb;
video_retime #(
	.M0_X0(10'd0), .M0_HT(10'd384), .M0_HS(10'd320), .M0_HW(10'd32), .M0_AW(10'd288), .M0_DIV(5'd16),
	.M1_X0(10'd0), .M1_HT(10'd384), .M1_HS(10'd320), .M1_HW(10'd32), .M1_AW(10'd288), .M1_DIV(5'd16),
	.LINE_CLKS(6144), .VTOTAL_P(264),
	.VS_A(10'd0), .VE_A(10'd224), .VS_B(10'd0), .VE_B(10'd224), .VS_REL(10'd16)
) video_retime (
	.clk_w(clk_sys), .reset_w(reset), .ce_w(ce_pix),
	.hcount_w({1'b0, hcnt}), .vcount_w({1'b0, vcnt}), .rgb_w(core_rgb),
	.mode1(1'b0), .tall240(1'b0),
	.clk_r(clk_sd),
	.ce_r(rt_ce), .rgb_r(rt_rgb), .hs_r(rt_hs), .vs_r(rt_vs), .de_r(),
	.hb_r(rt_hb), .vb_r(rt_vb), .vb_hs_r(rt_vb_hs)
);

// the in-core flip: every frame through DDR, shown turned a frame later
wire        fl_ce, fl_hs, fl_vs, fl_hb, fl_vb, fl_vb_hs;
wire [23:0] fl_rgb;
wire        fl_owns, fl_rd, fl_we;
wire  [7:0] fl_burstcnt, fl_be;
wire [28:0] fl_addr;
wire [63:0] fl_din;
ns2_flipbuf flipbuf (
	.clk(clk_sd), .enable(flip_180 & no_rotate),
	.ce_in(rt_ce), .rgb_in(rt_rgb), .hs_in(rt_hs), .vs_in(rt_vs), .hb_in(rt_hb), .vb_in(rt_vb), .vb_hs_in(rt_vb_hs),
	.ce_out(fl_ce), .rgb_out(fl_rgb), .hs_out(fl_hs), .vs_out(fl_vs), .hb_out(fl_hb), .vb_out(fl_vb), .vb_hs_out(fl_vb_hs),
	.owns(fl_owns), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(fl_burstcnt), .DDRAM_ADDR(fl_addr),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(fl_rd),
	.DDRAM_DIN(fl_din), .DDRAM_BE(fl_be), .DDRAM_WE(fl_we)
);
assign CLK_VIDEO = clk_sd;

// the scandoubler is off whenever the rotation framebuffer is on (NMK-28):
// rotating, or turning the picture 180 degrees
wire       fb_rotating = ~no_rotate;
wire [2:0] fx = direct_video ? 3'd0 : status[3:1];
wire       scandoubler_en = ((fx != 3'd0) || forced_scandoubler) && ~fb_rotating;
assign VGA_SL = fx[2:1];

wire        vm_ce_pix, vm_hs, vm_vs, vm_hb, vm_vb;
wire [23:0] retimed_rgb;
wire        crt_on = status[101] & ~scandoubler_en & ~fb_rotating;
crt_chain #(
	.HTOTAL0(10'd384), .HTOTAL1(10'd384), .DIV0(5'd16), .DIV1(5'd16),
	.VTOTAL(264), .LINE_PX(304), .VSIZE_MAX(VSIZE_MAX)
) crt_chain (
	.clk(clk_sd), .ce_in(fl_ce), .rgb_in(fl_rgb),
	.hs_in(fl_hs), .vs_in(fl_vs), .hb_in(fl_hb), .vb_in(fl_vb), .vb_hs_in(fl_vb_hs),
	.mode1(1'b0), .enable(crt_on),
	.hsize($signed(status[100:96])), .hpos_raw(status[85:79]),
	.vshift($signed(status[78:74])), .vsize_code(status[107:104]),
	.vsize_mode(status[108]),
	.ce_out(vm_ce_pix), .rgb_out(retimed_rgb),
	.hs_out(vm_hs), .vs_out(vm_vs), .hb_out(vm_hb), .vb_out(vm_vb)
);

video_mixer #(.LINE_LENGTH(304), .HALF_DEPTH(0), .GAMMA(0)) video_mixer (
	.CLK_VIDEO(CLK_VIDEO),
	.ce_pix(vm_ce_pix),
	.CE_PIXEL(CE_PIXEL),
	.scandoubler(scandoubler_en),
	.hq2x(fx == 3'd1),
	.gamma_bus(vm_gamma_bus),
	.R(retimed_rgb[23:16]), .G(retimed_rgb[15:8]), .B(retimed_rgb[7:0]),
	.HSync(vm_hs), .VSync(vm_vs), .HBlank(vm_hb), .VBlank(vm_vb),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

// ------------------------------------------------------------------
// Orientation: the sets are ROT0; "Vert 90" and "Vert 270" are for
// cabinets whose monitor is on its side.
// ------------------------------------------------------------------
wire        video_rotated;
// screen_rotate's side of the DDR port
wire  [7:0] sr_burstcnt, sr_be;
wire [28:0] sr_addr;
wire [63:0] sr_din;
wire        sr_we, sr_rd;
wire        rotate_ccw = (orientation == 2'd2);
screen_rotate screen_rotate (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(flip_180 & ~no_rotate), .video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(sr_burstcnt), .DDRAM_ADDR(sr_addr),
	.DDRAM_DIN(sr_din), .DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(sr_rd)
);
// the DDR port: the flip buffer's while it has a frame or a transfer,
// screen_rotate's otherwise (they are never wanted together)
assign DDRAM_BURSTCNT = fl_owns ? fl_burstcnt : sr_burstcnt;
assign DDRAM_ADDR     = fl_owns ? fl_addr     : sr_addr;
assign DDRAM_DIN      = fl_owns ? fl_din      : sr_din;
assign DDRAM_BE       = fl_owns ? fl_be       : sr_be;
assign DDRAM_WE       = fl_owns ? fl_we       : sr_we;
assign DDRAM_RD       = fl_owns ? fl_rd       : sr_rd;
assign FB_FORCE_BLANK = 1'b0;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
