// The OSD's Flip screen inside the core (NS2-22): a 180-degree turn of the
// picture on every video path (the HDMI scaler, the analog board, direct
// video), which the framework's framebuffer flip (screen_rotate) reaches only
// on HDMI.
//
// The board draws a line during the line before it, and the games change
// their registers and video RAM mid-frame (NS2-5's bands), so the picture
// cannot be drawn bottom-up. Instead each frame goes to DDR as it is shown,
// and the next frame's time shows it turned: line y is the stored frame's
// line 223 - y, read backwards. One frame late while on; off, the stream
// passes unchanged.
//
// It sits on video_retime's output (CLK_VIDEO, clk_sd), after which every
// signal is delayed one clock. DDR: two frames of 224 lines, each line 144
// words of two pixels ({8'd0, odd, 8'd0, even}), at a 2 KB stride, from
// 0x30000000 (screen_rotate's buffers are at 0x24000000). The port is the
// framework's; `owns` says this module is using it (the top gives it to
// screen_rotate otherwise), and it lets go only between transfers.
module ns2_flipbuf (
	input             clk,          // CLK_VIDEO (the DDR port's clock)
	input             enable,       // flip wanted (taken at a frame's start)
	// video_retime's stream
	input             ce_in,
	input      [23:0] rgb_in,
	input             hs_in, vs_in, hb_in, vb_in, vb_hs_in,
	// the same, one clock later, the picture turned when on
	output reg        ce_out,
	output reg [23:0] rgb_out,
	output reg        hs_out, vs_out, hb_out, vb_out, vb_hs_out,
	// DDR (Avalon, 64-bit words)
	output            owns,
	input             DDRAM_BUSY,
	output reg  [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output reg        DDRAM_WE
);
	localparam [28:0] BASE = 29'h06000000;   // 0x30000000 / 8
	localparam        W    = 288;            // pixels a line
	localparam        H    = 224;            // lines
	localparam        PAIRS = W / 2;         // words a line

	// ---------------------------------------------------------- the raster
	// x: the active pixel within the line; y: the active line
	reg        de_d = 1'b0, vb_d = 1'b1;
	reg  [8:0] x = 9'd0;
	reg  [7:0] y = 8'd0;
	reg        wf = 1'b0;                    // the frame being written
	reg        on = 1'b0;                    // flipping this frame
	reg  [1:0] filled = 2'd0;                // frames written while on (to 2)
	wire       de = ~hb_in & ~vb_in;
	wire       vb_rise = ce_in & vb_in & ~vb_d;
	always @(posedge clk) if (ce_in) begin
		de_d <= de;
		vb_d <= vb_in;
		if (de) x <= x + 9'd1;
		if (de_d & ~de) begin x <= 9'd0; y <= y + 8'd1; end
		if (vb_in) y <= 8'd0;
		if (vb_in & ~vb_d) begin
			wf <= ~wf;
			on <= enable;
			filled <= !enable ? 2'd0 : (filled == 2'd2) ? 2'd2 : filled + 2'd1;
		end
	end
	// a frame shows turned once one whole frame has been stored
	wire show = on && filled == 2'd2;

	// ---------------------------------------------------------- the write side
	// pixel pairs into a FIFO, with the frame's first pair marked
	reg  [23:0] even;
	(* ramstyle = "MLAB, no_rw_check" *) reg [49:0] fifo [0:63];                 // {sof, frame, odd, even}
	reg   [6:0] f_w = 7'd0, f_r = 7'd0;
	wire  [6:0] f_n = f_w - f_r;
	always @(posedge clk) if (ce_in && de && on) begin
		if (!x[0]) even <= rgb_in;
		else begin
			fifo[f_w[5:0]] <= {x == 9'd1 && y == 8'd0, wf, rgb_in, even};
			f_w <= f_w + 7'd1;
		end
	end
	wire [49:0] f_q = fifo[f_r[5:0]];

	// ---------------------------------------------------------- the DDR port
	// a read of a line: 9 bursts of 16, back to IDLE between them, where a
	// FIFO a quarter full writes first; a write: 8 pairs from the FIFO
	reg        fetch = 1'b0;                 // a line wanted
	reg        fetch_drain = 1'b0;           // ...after the FIFO empties
	reg  [7:0] f_line;                       // the line shown
	localparam [2:0] IDLE = 3'd0, WR = 3'd1, RD = 3'd2, RDW = 3'd3;
	reg  [2:0] st = IDLE;
	reg  [7:0] w_line = 8'd0;
	reg  [7:0] w_pair = 8'd0;
	reg        w_fr = 1'b0;
	reg  [3:0] beats;
	reg  [7:0] r_src;                        // the source line
	reg        r_half;
	reg        r_fr;
	reg  [3:0] r_burst;                      // 0..8
	reg  [7:0] r_pair;                       // the next word's pair
	reg  [4:0] r_left;                       // words of the burst to come
	reg        reading = 1'b0;               // a line part-read
	wire       write_first = f_n >= 7'd16;
	wire       fetch_go = st == IDLE && !reading && fetch && (!fetch_drain || f_n == 7'd0) && !write_first;
	wire       read_go  = st == IDLE && reading && !write_first;
	wire       write_go = st == IDLE && !fetch_go && !read_go && f_n >= 7'd8;
	// ---------------------------------------------------------- the read side
	// line y shows source line 223 - y, fetched from the start of line y - 1
	// (line 0 in the blank, once the last line has left the FIFO) into half
	// y[0], the half not being shown
	(* ramstyle = "M10K" *) reg [47:0] lb [0:511];
	always @(posedge clk) begin
		if (ce_in && on && de && !de_d && y != H - 1) begin
			fetch <= 1'b1; fetch_drain <= 1'b0; f_line <= y + 8'd1;
		end else if (vb_rise && enable) begin
			fetch <= 1'b1; fetch_drain <= 1'b1; f_line <= 8'd0;
		end else if (fetch_go) fetch <= 1'b0;
	end

	assign owns = on || st != IDLE || f_n != 7'd0;
	assign DDRAM_BE  = 8'hff;
	assign DDRAM_DIN = {8'd0, f_q[47:24], 8'd0, f_q[23:0]};

	// a FIFO entry's line and pair (the first of a frame restarts the count)
	wire  [7:0] e_line = f_q[49] ? 8'd0 : w_line;
	wire  [7:0] e_pair = f_q[49] ? 8'd0 : w_pair;
	always @(posedge clk) begin
		case (st)
		IDLE: begin
			if (fetch_go) begin
				r_src   <= (H - 1) - f_line;
				r_half  <= f_line[0];
				r_fr    <= ~wf;                  // the frame last completed
				r_burst <= 4'd0;
				r_pair  <= 8'd0;
				reading <= 1'b1;
				st      <= RD;
			end else if (read_go) begin
				st      <= RD;
			end else if (write_go) begin
				w_fr           <= f_q[49] ? f_q[48] : w_fr;
				DDRAM_ADDR     <= BASE + {12'd0, f_q[49] ? f_q[48] : w_fr, e_line, e_pair};
				DDRAM_BURSTCNT <= 8'd8;
				DDRAM_WE       <= 1'b1;
				w_line         <= e_line;
				w_pair         <= e_pair;
				beats          <= 4'd0;
				st             <= WR;
			end
		end
		WR: if (!DDRAM_BUSY) begin
			// a beat taken: the next pair
			f_r <= f_r + 7'd1;
			if (w_pair == PAIRS - 1) begin w_pair <= 8'd0; w_line <= w_line + 8'd1; end
			else w_pair <= w_pair + 8'd1;
			beats <= beats + 4'd1;
			if (beats == 4'd7) begin DDRAM_WE <= 1'b0; st <= IDLE; end
		end
		RD: begin
			DDRAM_ADDR     <= BASE + {12'd0, r_fr, r_src, r_burst, 4'd0};
			DDRAM_BURSTCNT <= 8'd16;
			DDRAM_RD       <= 1'b1;
			r_left         <= 5'd16;
			st             <= RDW;
		end
		RDW: begin
			if (DDRAM_RD && !DDRAM_BUSY) DDRAM_RD <= 1'b0;
			if (DDRAM_DOUT_READY) begin
				r_pair <= r_pair + 8'd1;
				r_left <= r_left - 5'd1;
				if (r_left == 5'd1) begin
					r_burst <= r_burst + 4'd1;
					if (r_burst == 4'd8) reading <= 1'b0;
					st <= IDLE;
				end
			end
		end
		default: st <= IDLE;
		endcase
	end

	always @(posedge clk) if (st == RDW && DDRAM_DOUT_READY) lb[{r_half, r_pair}] <= {DDRAM_DOUT[55:32], DDRAM_DOUT[23:0]};

	// ---------------------------------------------------------- the output
	// pixel x of line y is the source's pixel 287 - x: its pair and half
	// are read ahead (the address holds for the whole pixel)
	wire [8:0] sx = (W - 1) - x;
	reg [47:0] lb_q;
	always @(posedge clk) lb_q <= lb[{y[0], sx[8:1]}];
	always @(posedge clk) begin
		ce_out    <= ce_in;
		hs_out    <= hs_in;
		vs_out    <= vs_in;
		hb_out    <= hb_in;
		vb_out    <= vb_in;
		vb_hs_out <= vb_hs_in;
		if (ce_in) rgb_out <= (show && de) ? (sx[0] ? lb_q[47:24] : lb_q[23:0]) : rgb_in;
	end
endmodule
