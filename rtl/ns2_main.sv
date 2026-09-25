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
	output     [17:1] srom_addr,
	input      [15:0] srom_data,
	output     [20:1] drom_addr,
	input      [15:0] drom_data,
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
	// 12.288 MHz: PHI1 and PHI2 alternate every two clocks
	reg [1:0] ph;
	always @(posedge clk) ph <= reset ? 2'd0 : ph + 1'd1;
	wire en_phi1 = ph == 2'd0, en_phi2 = ph == 2'd2;

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
		.rom_addr(mrom_addr), .rom_data(mrom_data),
		.vblank(vblank), .posirq(posirq), .cpuirq_in(s_irq), .cpuirq_out(m_irq), .ext1(ext1), .ext2(ext2),
		.sh_req(m_req), .sh_addr(m_sa), .sh_we(m_we), .sh_uds(m_uds), .sh_lds(m_lds), .sh_dout(m_sd),
		.sh_done(m_done), .sh_din(sh_q),
		.dbg_as(m_as), .dbg_addr(m_addr), .dbg_rnw(m_rnw), .dbg_wdata(m_wdata), .dbg_ds(m_ds), .dbg_iack(), .dbg_rdata(m_rdata), .dbg_dtack(m_dtack));
	ns2_cpu #(.MASTER(0)) u_slave (
		.clk(clk), .reset(reset), .run(ext2[0]), .en_phi1(en_phi1), .en_phi2(en_phi2),
		.rom_addr(srom_addr), .rom_data(srom_data),
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
	reg [15:0] sci_q;

	// the arbiter: grant, then two clocks (address, then data)
	reg        busy, who;           // who: 0 master, 1 slave
	reg  [1:0] step;
	reg [3:0]  dev;
	wire       fl = board == 3'd1;
	localparam D_NONE = 0, D_DROM = 1, D_VID = 2, D_DP = 3, D_SCI = 4, D_KEY = 5, D_PROT = 6;
	wire [23:0] ga = {who ? s_sa : m_sa, 1'b0};
	function [3:0] decode(input [23:0] x);
		if (x[23:21] == 3'b001)                 decode = D_DROM;   // 200000-3fffff
		else if (x[23:17] == 7'h20)             decode = D_VID;    // 400000-41ffff
		else if (x[23:6] == 18'h10800)          decode = D_VID;    // 420000-42003f
		else if (x[23:16] == 8'h44)             decode = D_VID;    // 440000-44ffff
		else if (x[23:16] == 8'h46)             decode = D_DP;     // 460000-46ffff
		else if (x[23:14] == 10'h120)           decode = D_SCI;    // 480000-483fff
		else if (!fl && x[23:14] == 10'h300)    decode = D_VID;    // c00000-c03fff
		else if (!fl && x[23:1] == 23'h620000)  decode = D_VID;    // c40000
		else if (!fl && x[23:17] == 7'h64)      decode = D_VID;    // c80000-c9ffff
		else if (!fl && x[23:4] == 20'hcc000)   decode = D_VID;    // cc0000-cc000f
		else if (!fl && x[23:4] == 20'hd0000)   decode = D_KEY;    // d00000-d0000f
		else if (fl && x[23:16] == 8'h80)       decode = D_VID;    // 800000-80ffff
		else if (fl && x[23:1] == 23'h420000)   decode = D_VID;    // 840000
		else if (fl && x[23:17] == 7'h44)       decode = D_VID;    // 880000-89ffff
		else if (fl && x[23:18] == 6'h0c)       decode = D_PROT;   // 300000-33ffff (inside the data ROM's window)
		else                                    decode = D_NONE;
	endfunction
	assign drom_addr = ga[20:1];

	always @(posedge clk) begin
		m_done <= 1'b0; s_done <= 1'b0;
		key_rd <= 1'b0; key_we <= 1'b0; dp_we <= 1'b0;
		{cs_tmap, cs_tctl, cs_pal, cs_spr, cs_gfx, cs_roz, cs_rozctl} <= 7'd0;
		if (reset) begin busy <= 1'b0; step <= 2'd0; end
		else if (!busy) begin
			// a new request, the master first
			if (m_req && !m_done) begin busy <= 1'b1; who <= 1'b0; step <= 2'd0; end
			else if (s_req && !s_done) begin busy <= 1'b1; who <= 1'b1; step <= 2'd0; end
		end else case (step)
			2'd0: begin
				// the address: select the device (its select is active next clock)
				dev <= decode(ga);
				v_addr <= ga[20:1]; v_dout <= who ? s_sd : m_sd; v_rnw <= !(who ? s_we : m_we);
				v_uds <= who ? s_uds : m_uds; v_lds <= who ? s_lds : m_lds;
				case (decode(ga))
					D_VID: begin
						cs_tmap   <= ga[23:17] == 7'h20;
						cs_tctl   <= ga[23:6] == 18'h10800;
						cs_pal    <= ga[23:16] == 8'h44;
						cs_spr    <= fl ? ga[23:16] == 8'h80 : ga[23:14] == 10'h300;
						cs_gfx    <= fl ? ga[23:1] == 23'h420000 : ga[23:1] == 23'h620000;
						cs_roz    <= fl ? ga[23:17] == 7'h44 : ga[23:17] == 7'h64;
						cs_rozctl <= !fl && ga[23:4] == 20'hcc000;
					end
					D_DP: begin
						dp_addr <= ga[11:1]; dp_dout <= (who ? s_sd : m_sd) & 8'hff;
						dp_we <= (who ? s_we : m_we) && (who ? s_lds : m_lds);
					end
					D_KEY: key_off <= ga[3:1];
					D_SCI: begin
						if ((who ? s_we : m_we) && (who ? s_uds : m_uds)) sci_h[ga[13:1]] <= (who ? s_sd : m_sd) >> 8;
						if ((who ? s_we : m_we) && (who ? s_lds : m_lds)) sci_l[ga[13:1]] <= (who ? s_sd : m_sd) & 8'hff;
					end
					default: ;
				endcase
				sci_q <= {sci_h[ga[13:1]], sci_l[ga[13:1]]};
				step <= 2'd1;
			end
			2'd1: begin
				// the devices latch their read data (the video's RAMs, the DPRAM);
				// the key's strobe lands on the capture clock, after its value is taken
				if (dev == D_KEY) begin key_rd <= !(who ? s_we : m_we); key_we <= who ? s_we : m_we; end
				step <= 2'd2;
			end
			default: begin
				// capture and complete
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
