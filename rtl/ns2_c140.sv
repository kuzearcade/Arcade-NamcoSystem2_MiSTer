// C140 (MAME c140.cpp): 24 PCM voices, the register file, the key-on status
// and the INT1 timer that drives the 6809's FIRQ.
//   0x000-0x17f  24 voices x 16 registers: 0 volume right, 1 volume left,
//                2-3 frequency, 4 bank, 5 mode (key-on on bit 7, or bit 6
//                while keyed; bit 4 loop, bit 3 compressed), 6-7 start,
//                8-9 end, 10-11 loop (sample words within the bank)
//   0x1f8        INT1 reload; reads back the written value + 1
//   0x1fa        a write clears INT1 and, when enabled, restarts the timer:
//                INT1 rises (reload + 1) * 2 base-rate ticks later
//   0x1fe        bit 0 enables INT1 (asserted at once when no timer runs);
//                0 clears it and stops the timer
// A read of register 5 returns bit 6 = the voice plays (MAME's keyon_status_read).
//
// The voices, as MAME's sound_stream_update, one sample per base-rate tick
// (21.333 kHz: clk / 2304; MAME_RATE = 1 uses MAME's stream edges instead,
// its integer 21333 Hz, for the sample-exact comparison):
//   offset += frequency * 2; pos += offset >> 16; offset &= 0xffff;
//   pos >= end - start: loop (pos = loop - start) or stop (the key clears);
//   a step fetches the word (bank << 16) + start + pos: 12 bits, linear or
//   compressed (MAME's table), >> 4; the voice interpolates its last two
//   words by offset and adds (dt * volume * 32 / 24) >> 9 to 16-bit
//   (wrapping) sums, clamped to +-4096 and scaled to 16 bits (MAME's
//   put_int_clamp).
// MAME computes the samples whose edge has passed before it applies a
// register write, so a write never reaches a sample being computed: the
// voice register writes wait in a queue while the voices run (the CPU's
// view, the register reads and the key status, changes at once). A tick
// first applies the writes made before it.
// Voice ROM words: c140_rom_r (namcos2_m.cpp), the schematics' wiring: word
// address bit 21 picks voice1/voice2 for bits 15-8, bit 20 low enables
// voice0's nibble for bits 7-4, bit 19 low picks its low nibble.
module ns2_c140 #(parameter MAME_RATE = 0) (
	input             clk,
	input             reset,
	input             cs,             // one clock strobe per access
	input             we,
	input      [8:0]  addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	output reg        int1,           // to the 6809's FIRQ (active high)
	// the voice ROM: the "c140" region's 16-bit words (voice1/2 on the high
	// byte, voice0 on the low); a request is answered by valid later
	output reg        rom_req,
	output reg [19:0] rom_addr,
	input             rom_valid,
	input      [15:0] rom_data,
	// the output, one sample per tick; raw_*: MAME's mixer sums (debug)
	output reg signed [15:0] left,
	output reg signed [15:0] right,
	output reg signed [15:0] raw_l,
	output reg signed [15:0] raw_r,
	output reg        sample
);
	reg [7:0]  regs [0:511];           // the CPU's view
	reg [23:0] key_cpu;                // the key status the CPU reads
	// the timer counts clocks from the write, as MAME's (an exact duration,
	// not the base-rate ticks' edges): (reload + 1) * 2 * 2304 clocks
	reg [20:0] tcount;
	reg        running;

	wire [4:0] voice = addr[8:4];
	always @(*) begin
		if (addr[3:0] == 4'h5 && addr < 9'h180) dout = {1'b0, key_cpu[voice], regs[addr][5:0]};
		else if (addr == 9'h1f8)             dout = regs[addr] + 1'd1;
		else                                 dout = regs[addr];
	end

	// ---------------------------------------------------------- the tick
	reg        tick;
	reg [11:0] div;
	reg [25:0] acc;
	always @(posedge clk) begin
		tick <= 1'b0;
		if (reset) begin div <= 0; acc <= 26'd49152000 - 26'd21333; end
		else if (MAME_RATE) begin
			// edge k at the first clock c with c * 21333 >= k * 49152000
			if (acc + 26'd21333 >= 26'd49152000) begin acc <= acc + 26'd21333 - 26'd49152000; tick <= 1'b1; end
			else acc <= acc + 26'd21333;
		end else begin
			div <= div == 12'd2303 ? 12'd0 : div + 1'd1;
			tick <= div == 12'd0;
		end
	end

	// ---------------------------------------------------------- the voices
	// the engine's registers (0-11 of each voice), written from the queue
	reg [7:0]  vol_r [0:23], vol_l [0:23], frq_h [0:23], frq_l [0:23], bnk [0:23];
	reg [7:0]  st_h [0:23], st_l [0:23], ed_h [0:23], ed_l [0:23], lp_h [0:23], lp_l [0:23];
	// the voices' state (MAME's C140_VOICE)
	reg        key [0:23];
	reg [15:0] offs [0:23];
	reg signed [17:0] pos [0:23];
	reg signed [15:0] lastdt [0:23], prevdt [0:23];
	reg [7:0]  mode [0:23], vbank [0:23];
	reg [15:0] vst [0:23], ved [0:23], vlp [0:23];

	// the queue of the CPU's voice register writes:
	// {key-on decision, voice[4:0], register[3:0], data[7:0]}
	(* ramstyle = "logic" *) reg [17:0] q [0:31];
	reg [4:0]  q_wr, q_rd, q_mark;
	reg        tick_p;
	wire [17:0] qe  = q[q_rd];
	wire [4:0]  qv  = qe[16:12];
	wire [3:0]  qr  = qe[11:8];
	wire [7:0]  qd  = qe[7:0];

	// the engine: a step pass (positions, the end), then a sound pass
	localparam E_IDLE = 0, E_STEP = 1, E_SND = 2, E_FETCH_H = 3, E_WAIT_H = 4, E_WAIT_L = 5, E_WORD = 6, E_MIX = 7, E_OUT = 8, E_MIX0 = 9;
	reg [3:0]  es;
	reg [4:0]  ev;                      // the voice
	reg [23:0] act, stp;               // this sample: the voice sounds; it stepped (a fetch)
	reg [23:0] wse;                    // the CPU wrote the voice's mode since the tick
	reg signed [15:0] lsum, rsum;
	reg [15:0] smp;
	reg [21:0] waddr;

	// MAME's compressed table: j = (s8)i; s1 = j & 7; s2 = abs(j >> 3) & 31;
	// v = ((0x80 << s1) & 0xff00) + (s2 << (s1 ? s1 + 3 : 4)); negative j negates
	function signed [15:0] pcm(input [7:0] i);
		reg [2:0]  s1;
		reg [7:0]  j3, a3;
		reg [16:0] v;
		begin
			s1 = i[2:0];
			j3 = {{3{i[7]}}, i[7:3]};           // j >> 3 (arithmetic)
			a3 = i[7] ? -j3 : j3;
			// the shift is 4 bits: s1 + 3 reaches 10 (NS2-26: in 3 bits, exponents
			// 5-7 shifted by 0-2, and loud compressed samples lost their mantissa)
			v  = ((17'h80 << s1) & 17'hff00) + ({12'd0, a3[4:0]} << (s1 != 0 ? {1'b0, s1} + 4'd3 : 4'd4));
			pcm = i[7] ? -v[15:0] : v[15:0];
		end
	endfunction

	// MAME's put_int_clamp(v, 4096): +-1.0 full scale, as 16 bits
	function signed [15:0] clamp(input signed [15:0] v);
		clamp = v > 16'sd4095 ? 16'sh7ff8 : v < -16'sd4096 ? -16'sh8000 : v <<< 3;
	endfunction

	// voice ev's step and sound (combinational from its state)
	wire [15:0] e_frq   = {frq_h[ev], frq_l[ev]};
	wire [17:0] e_sum   = {2'b00, offs[ev]} + {1'b0, e_frq, 1'b0};   // < 0x30000
	wire [1:0]  e_cnt   = e_sum[17:16];
	wire signed [17:0] e_pos  = pos[ev] + $signed({16'd0, e_cnt});
	wire signed [17:0] e_sz   = $signed({2'b00, ved[ev]}) - $signed({2'b00, vst[ev]});
	wire signed [17:0] e_loop = $signed({2'b00, vlp[ev]}) - $signed({2'b00, vst[ev]});
	wire signed [15:0] e_lin  = $signed(smp & 16'hfff0) >>> 4;
	wire signed [15:0] e_cmp  = pcm(smp[15:8]) >>> 4;
	wire signed [15:0] e_new  = mode[ev][3] ? e_cmp : e_lin;
	wire signed [16:0] e_dlt  = {lastdt[ev][15], lastdt[ev]} - {prevdt[ev][15], prevdt[ev]};
	wire signed [33:0] e_mul  = e_dlt * $signed({1'b0, offs[ev]});
	wire signed [17:0] e_dt   = e_mul[33:16] + {{2{prevdt[ev][15]}}, prevdt[ev]};
	wire [9:0]  e_lvol = ({2'b00, vol_l[ev]} * 10'd4) / 10'd3;
	wire [9:0]  e_rvol = ({2'b00, vol_r[ev]} * 10'd4) / 10'd3;
	// the mix in two clocks (E_MIX0 the voice's sample and volumes, E_MIX the
	// products): one is too long a path
	reg signed [17:0] m_dt;
	reg [9:0]  m_lvol, m_rvol;
	wire signed [28:0] e_lp = m_dt * $signed({1'b0, m_lvol});
	wire signed [28:0] e_rp = m_dt * $signed({1'b0, m_rvol});
	wire [23:0] e_word = {vbank[ev], 16'd0} + {8'd0, vst[ev]} + {{6{pos[ev][17]}}, pos[ev]};
	wire        e_kon  = din[7] || (din[6] && key_cpu[voice]);

	integer i;
	always @(posedge clk) begin
		sample <= 1'b0; rom_req <= 1'b0;
		if (reset) begin
			key_cpu <= 0; int1 <= 1'b0; running <= 1'b0; tcount <= 0;
			q_wr <= 0; q_rd <= 0; q_mark <= 0; tick_p <= 1'b0; es <= E_IDLE; wse <= 0;
			for (i = 0; i < 24; i = i + 1) begin
				key[i] <= 1'b0; offs[i] <= 0; pos[i] <= 0; lastdt[i] <= 0; prevdt[i] <= 0;
				mode[i] <= 0; vbank[i] <= 0; vst[i] <= 0; ved[i] <= 0; vlp[i] <= 0;
				vol_r[i] <= 0; vol_l[i] <= 0; frq_h[i] <= 0; frq_l[i] <= 0; bnk[i] <= 0;
				st_h[i] <= 0; st_l[i] <= 0; ed_h[i] <= 0; ed_l[i] <= 0; lp_h[i] <= 0; lp_l[i] <= 0;
			end
			left <= 0; right <= 0; raw_l <= 0; raw_r <= 0;
		end else begin
			// ------------------------------------------------ the CPU
			if (running) begin
				if (tcount == 21'd1) begin int1 <= 1'b1; running <= 1'b0; end
				tcount <= tcount - 1'd1;
			end
			if (tick) begin wse <= 0; tick_p <= 1'b1; q_mark <= q_wr; end
			if (cs && we) begin
				regs[addr] <= din;
				if (addr < 9'h180 && addr[3:0] < 4'd12) begin
					// the key-on decision is MAME's, at the write
					if (addr[3:0] == 4'h5) begin key_cpu[voice] <= e_kon; wse[voice] <= 1'b1; end
					q[q_wr] <= {addr[3:0] == 4'h5 && e_kon, voice, addr[3:0], din};
					q_wr <= q_wr + 1'd1;
				end
				if (addr == 9'h1fa) begin
					int1 <= 1'b0;
					if (regs[9'h1fe][0]) begin running <= 1'b1; tcount <= ({13'd0, regs[9'h1f8]} + 21'd1) * 21'd4608; end
				end
				if (addr == 9'h1fe) begin
					if (din[0]) begin if (!running) int1 <= 1'b1; end
					else begin int1 <= 1'b0; running <= 1'b0; end
				end
			end

			// ------------------------------------------------ the engine
			case (es)
				E_IDLE: begin
					if (q_rd != (tick_p ? q_mark : q_wr)) begin
						// apply a queued write (the writes before a tick first)
						q_rd <= q_rd + 1'd1;
						case (qr)
							4'd0:  vol_r[qv] <= qd;
							4'd1:  vol_l[qv] <= qd;
							4'd2:  frq_h[qv] <= qd;
							4'd3:  frq_l[qv] <= qd;
							4'd4:  bnk[qv]   <= qd;
							4'd5:  if (qe[17]) begin
								key[qv] <= 1'b1; offs[qv] <= 0; pos[qv] <= 0; lastdt[qv] <= 0; prevdt[qv] <= 0;
								vbank[qv] <= bnk[qv]; mode[qv] <= qd;
								vst[qv] <= {st_h[qv], st_l[qv]}; ved[qv] <= {ed_h[qv], ed_l[qv]}; vlp[qv] <= {lp_h[qv], lp_l[qv]};
							end else key[qv] <= 1'b0;
							4'd6:  st_h[qv] <= qd;
							4'd7:  st_l[qv] <= qd;
							4'd8:  ed_h[qv] <= qd;
							4'd9:  ed_l[qv] <= qd;
							4'd10: lp_h[qv] <= qd;
							default: lp_l[qv] <= qd;
						endcase
					end else if (tick_p) begin
						tick_p <= 1'b0; es <= E_STEP; ev <= 0; lsum <= 0; rsum <= 0;
					end
				end
				E_STEP: begin
					// MAME's per-sample step, voice ev
					act[ev] <= 1'b0; stp[ev] <= 1'b0;
					if (key[ev] && e_frq != 0) begin
						offs[ev] <= e_sum[15:0];
						if (e_pos >= e_sz) begin
							if (mode[ev][4]) begin
								pos[ev] <= e_loop; act[ev] <= 1'b1; stp[ev] <= e_cnt != 0;
							end else begin
								pos[ev] <= e_pos; key[ev] <= 1'b0;
								if (!wse[ev]) key_cpu[ev] <= 1'b0;
							end
						end else begin
							pos[ev] <= e_pos; act[ev] <= 1'b1; stp[ev] <= e_cnt != 0;
						end
					end
					if (ev == 5'd23) begin ev <= 0; es <= E_SND; end
					else ev <= ev + 1'd1;
				end
				E_SND: begin
					if (!act[ev]) es <= E_OUT;
					else if (stp[ev]) es <= E_FETCH_H;
					else es <= E_MIX0;
				end
				E_FETCH_H: begin
					waddr <= e_word[21:0];
					rom_req <= 1'b1; rom_addr <= {e_word[21], e_word[18:0]};
					es <= E_WAIT_H;
				end
				E_WAIT_H: if (rom_valid) begin
					smp <= rom_data & 16'hff00;
					if (!waddr[20]) begin rom_req <= 1'b1; rom_addr <= {1'b0, waddr[18:0]}; es <= E_WAIT_L; end
					else es <= E_WORD;
				end
				E_WAIT_L: if (rom_valid) begin
					smp <= smp | {8'd0, (waddr[19] ? rom_data[7:0] : {rom_data[3:0], 4'd0}) & 8'hf0};
					es <= E_WORD;
				end
				E_WORD: begin
					// the word is complete: shift the history
					prevdt[ev] <= lastdt[ev]; lastdt[ev] <= e_new;
					es <= E_MIX0;
				end
				E_MIX0: begin
					m_dt <= e_dt; m_lvol <= e_lvol; m_rvol <= e_rvol;
					es <= E_MIX;
				end
				E_MIX: begin
					lsum <= lsum + e_lp[24:9];
					rsum <= rsum + e_rp[24:9];
					es <= E_OUT;
				end
				E_OUT: begin
					if (ev == 5'd23) begin
						raw_l <= lsum; raw_r <= rsum;
						left <= clamp(lsum); right <= clamp(rsum); sample <= 1'b1;
						es <= E_IDLE;
					end else begin ev <= ev + 1'd1; es <= E_SND; end
				end
				default: es <= E_IDLE;
			endcase
		end
	end
endmodule
