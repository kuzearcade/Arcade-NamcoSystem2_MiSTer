// Cheat engine — applies Pugsy MAME-database pokes to work RAM once a frame.
//
// MiSTer's CONF_STR is compiled into the core and shared by every game on the
// .rbf, so a per-game menu of cheat NAMES cannot be built. The core therefore
// offers SLOTS fixed, well-known cheats (Infinite Credits, P1/P2
// Invincibility, P1/P2 Infinite Lives, P1/P2 Infinite Bombs) and each .mra
// supplies that game's addresses for them as its <rom index="5"> region. A
// slot the loaded game has no entry for reports itself unavailable, and the
// top level hides it from the OSD through status_menumask.
//
// Table layout (big-endian), 2 + ACTS*6 bytes per slot, SLOTS slots --
// written by tools/gen_cheats_mra.py:
//     1 byte   count for this slot (0..ACTS)
//     1 byte   reserved
//     ACTS x { 3 bytes address, 1 byte kind, 2 bytes value }
//   kind bit 0: 0 = byte, 1 = word (high byte first)
//   kind bit 1: MASKED byte -- new = (old & ~hi) | lo, i.e. the value byte
//               is `lo` and `hi` is the mask of bits it owns. Pugsy writes
//               these as  X|(maincpu.pb@A BAND ~M)  (lomakai's key and
//               shield cheats). The old byte is read through ram_dout, the
//               same shared back door the hiscore module reads.
//
// MS1-Z extends MS1BCD's engine: ACTS defaults to 3 (lomakai's Infinite Time
// is three byte writes at odd addresses two apart, which no word can cover)
// and the masked kind is new. A table written for the old engine -- kind 0
// or 1, ACTS 2 -- means exactly what it meant before once ACTS matches.
//
// Writes go out on the same shared game-RAM port the hiscore module uses, so
// this adds no RAM port of its own (NMK-10 — see docs/known-issues.md). The
// port is only driven while pause_cpu is asserted and the top level has
// granted it, and a whole frame's pokes are at most ACTS*SLOTS*2 = 28 bytes,
// so the CPU stall is a few dozen cycles out of ~700,000 in a frame.
//
// Poke semantics follow MAME's "run" state: the value is written every frame
// for as long as the cheat is enabled, which is what makes "infinite" cheats
// hold against the game decrementing the counter.
module cheats #(
	parameter SLOTS = 7,
	parameter ACTS  = 3
) (
	input                    clk,
	input                    reset,

	// Table load, .mra <rom index="5">
	input                    ioctl_download,
	input                    ioctl_wr,
	input             [24:0] ioctl_addr,
	input             [15:0] ioctl_index,
	input              [7:0] ioctl_dout,

	input        [SLOTS-1:0] enable,      // OSD toggles
	output       [SLOTS-1:0] available,   // slot has data in this game's table

	input                    vblank,      // once-per-frame trigger

	// Shared work-RAM port (same contract as the hiscore port)
	output reg        [23:0] ram_addr,
	output reg         [7:0] ram_din,
	output reg               ram_write,
	output reg               ram_access,
	input              [7:0] ram_dout,    // the back door's read data (1 clk after the address)
	output reg               pause_cpu,
	// NS2 (local change): the back door is ready (the CPUs stopped and the
	// shared bus idle, some clocks after pause_cpu); the walk waits for it
	input                    paused,
	// NS2 (NS2-33): the back door is not ready this clock (its work RAM
	// behind a cache in the SDRAM: a miss, or a write waiting for room);
	// the walk holds, and the RAM looks as the block RAM it was
	input                    stall
);

	localparam BYTES_PER_SLOT = 2 + ACTS*6;
	localparam TBL_BYTES      = SLOTS*BYTES_PER_SLOT;
	localparam TW             = $clog2(TBL_BYTES);

	// NS2 (local change): the table is a block RAM read a byte at a time (the
	// engine reads a slot's count, then each action's six bytes, into
	// registers); held in registers with combinational reads it took 1,600
	// ALMs at ten slots. A slot is available when its count byte, as it is
	// downloaded, is non-zero.
	(* ramstyle = "M10K" *) reg [7:0] tbl [0:(1 << TW) - 1];
	reg  [TW-1:0]    rd_a;
	reg  [7:0]       rd_q;
	reg              loaded = 1'b0;
	reg  [SLOTS-1:0] avail = {SLOTS{1'b0}};
	assign available = loaded ? avail : {SLOTS{1'b0}};

	wire tbl_we = ioctl_download & ioctl_wr & (ioctl_index == 16'd5) & (ioctl_addr < TBL_BYTES);
	always @(posedge clk) begin
		if (tbl_we) tbl[ioctl_addr[TW-1:0]] <= ioctl_dout;
		rd_q <= tbl[rd_a];
	end
	integer k;
	always @(posedge clk) begin
		if (ioctl_download & (ioctl_index == 16'd5) & ~loaded) avail <= {SLOTS{1'b0}};
		if (tbl_we) begin
			loaded <= 1'b1;
			for (k = 0; k < SLOTS; k = k + 1)
				if (ioctl_addr == k * BYTES_PER_SLOT) avail[k] <= ioctl_dout != 8'd0;
		end
	end

	// ------------------------------------------------------------------
	// Per-frame poke walk. One byte per pass through S_WRITE; a word action
	// is just two byte writes, high byte first (68000 big-endian).
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE = 4'd0, S_WAIT = 4'd1, S_SLOT = 4'd2, S_CNT = 4'd3, S_FETCH = 4'd4,
	                 S_ACT = 4'd5, S_READ = 4'd6, S_HOLD = 4'd7, S_NEXT = 4'd8, S_DONE = 4'd9;

	reg  [3:0]  state = S_IDLE;
	reg  [3:0]  slot;
	reg  [3:0]  act;
	reg  [3:0]  cnt;
	reg  [2:0]  fb;          // the action byte being fetched (0-5), and the read's pipeline
	reg         fv;
	reg         half;        // 0 = first byte, 1 = second byte of a word
	reg  [2:0]  hold;
	reg         vblank_d;
	reg  [23:0] a_addr;
	reg  [7:0]  a_kind, a_hi, a_lo;
	wire        a_word = a_kind[0];
	wire        a_mask = a_kind[1] & ~a_kind[0];
	wire [TW-1:0] base = slot * BYTES_PER_SLOT;

	always @(posedge clk) begin
		vblank_d  <= vblank;
		if (!stall) ram_write <= 1'b0;

		if (reset) begin
			state <= S_IDLE; ram_access <= 1'b0; pause_cpu <= 1'b0;
		end else if (stall) ;
		else case (state)
			S_IDLE: begin
				ram_access <= 1'b0;
				pause_cpu  <= 1'b0;
				// rising edge of vblank, and only if something is enabled
				if (~vblank_d & vblank & loaded & |(enable & avail)) begin
					slot <= 4'd0; pause_cpu <= 1'b1; state <= S_WAIT;
				end
			end
			S_WAIT: if (paused) state <= S_SLOT;
			S_SLOT: begin
				if (slot >= SLOTS) state <= S_DONE;
				else if (enable[slot] & avail[slot]) begin
					rd_a <= base; hold <= 3'd2; state <= S_CNT;
				end else slot <= slot + 4'd1;
			end
			S_CNT: begin
				// the count byte, two clocks after its address
				if (hold != 3'd0) hold <= hold - 3'd1;
				else begin
					cnt <= rd_q[3:0]; act <= 4'd0; half <= 1'b0;
					rd_a <= base + 2'd2; fb <= 3'd0; fv <= 1'b0; state <= S_FETCH;
				end
			end
			S_FETCH: begin
				// an action's six bytes, a byte every two clocks
				if (act >= cnt) begin slot <= slot + 4'd1; state <= S_SLOT; end
				else if (!fv) fv <= 1'b1;
				else begin
					fv <= 1'b0;
					case (fb)
						3'd0: a_addr[23:16] <= rd_q;
						3'd1: a_addr[15:8]  <= rd_q;
						3'd2: a_addr[7:0]   <= rd_q;
						3'd3: a_kind        <= rd_q;
						3'd4: a_hi          <= rd_q;
						default: a_lo       <= rd_q;
					endcase
					rd_a <= rd_a + 1'd1;
					if (fb == 3'd5) begin fb <= 3'd0; state <= S_ACT; end
					else fb <= fb + 3'd1;
				end
			end
			S_ACT: begin
				if (a_mask) begin
					// masked byte: read first (S_READ), then merge and write
					ram_addr   <= a_addr;
					ram_access <= 1'b1;
					hold       <= 3'd3;
					state      <= S_READ;
				end else begin
					// byte action writes a_lo at the address; word writes
					// a_hi then a_lo across addr, addr+1.
					ram_addr   <= a_word ? (a_addr + {23'd0, half}) : a_addr;
					ram_din    <= a_word ? (half ? a_lo : a_hi) : a_lo;
					ram_access <= 1'b1;
					ram_write  <= 1'b1;
					hold       <= 3'd2;
					state      <= S_HOLD;
				end
			end
			S_READ: begin
				ram_access <= 1'b1;
				if (hold != 3'd0) hold <= hold - 3'd1;
				else begin
					ram_din   <= (ram_dout & ~a_hi) | (a_lo & a_hi);
					ram_write <= 1'b1;
					hold      <= 3'd2;
					state     <= S_HOLD;
				end
			end
			S_HOLD: begin
				ram_access <= 1'b1;
				if (hold != 3'd0) hold <= hold - 3'd1;
				else state <= S_NEXT;
			end
			S_NEXT: begin
				if (a_word & ~half) begin
					half <= 1'b1; state <= S_ACT;
				end else begin
					half <= 1'b0; act <= act + 4'd1; state <= S_FETCH;
				end
			end
			S_DONE: begin
				ram_access <= 1'b0;
				pause_cpu  <= 1'b0;
				state      <= S_IDLE;
			end
			default: state <= S_IDLE;
		endcase
	end

endmodule
