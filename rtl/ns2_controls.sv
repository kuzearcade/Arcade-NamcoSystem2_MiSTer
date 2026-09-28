// The players' controls onto the I/O MCU's ports (namcos2.cpp's input
// ports): the digital ports MCUB, MCUC, MCUH and the eight analog channels
// AN0-AN7, per the set's control mode (config byte 33, tools/ns2_romdata.py):
//   [1:0] 0 digital (MAME's default ports), 1 wheel and pedals, 2 light
//         guns, 3 Metal Hawk's analog stick
//   [2]   the gear shift is a toggle on MCUH bit 5 (B3: Final Lap, Four Trax)
//   [3]   Lucky & Wild: the wheel and pedals and the guns
//   the guns:
//   [5:4] their channels: 0 AN0 X1, AN1 Y1, AN2 X2, AN3 Y2 (Golly!
//         Ghost!, Bubble Trouble); 1 AN4 X1, AN5 X2, AN6 Y1, AN7 Y2 (Steel
//         Gunner); 2 AN4 X1, AN2 Y1, AN3 X2, AN1 Y2 (Lucky & Wild)
//   [6]   a gun's value is 255 - its position (Bubble Trouble)
//   [7]   the triggers are MCUB bits 5 (P1) and 4 (P2) (Golly! Ghost!,
//         Bubble Trouble); otherwise MCUH 5 and 4, the bombs MCUH 3 and 2
//   the wheel and pedals:
//   [4]   Start on MCUB 7 / 6 (Four Trax, Suzuka)
//   [5]   the gears on MCUB: 5 down (the d-pad's up), 7 up (down) (Dirt Fox)
// Modes other than 0 set only their inputs' bits of MCUB and MCUH; the other
// bits hold the set's idle values (config bytes 34-35: MAME's DIP defaults,
// and 0 where no field is defined), as MAME reads them.
// A gun's value is its position across the board's own picture, 0 at the
// left (top) to 255 at the right (bottom), as MAME's crosshair maps it; the
// players aim at the displayed picture, turned 180 degrees when `flip`.
// Wheel: 0x01-0xff, 0x80 centred; accelerator 0-0x80, brake 0-0x40; Metal
// Hawk's stick and lever 0x20-0xe0 (MAME's PORT_MINMAX). A stick sets a
// value outright; a button or the d-pad moves it a step a frame, as MAME's
// key delta, and it returns when released.
module ns2_controls (
	input             clk,
	input             reset,
	input             vblank,        // a step a frame, on its rise
	input      [7:0]  mode,
	input             flip,          // the picture is shown turned 180 degrees
	input      [63:0] an_default,    // MAME's power-on AN0-AN7 (config bytes 21-28)
	input      [7:0]  idle_b, idle_h, // MCUB's and MCUH's idle values (config bytes 34-35)
	// players: [0] R [1] L [2] D [3] U [4] B1 [5] B2 [6] B3 [7] B4 [8] B5
	input      [8:0]  p1, p2,
	input             start1, start2, coin1, coin2, svc1, svc2,
	input      [15:0] stick1, stick2, // left sticks {Y, X}, signed; a light gun's position
	input      [15:0] rstick1,        // player 1's right stick {Y, X}
	input      [24:0] mouse,          // ps2_mouse: [24] toggles per packet, [15:8] dx, [23:16] dy, [0] L [1] R
	output reg [7:0]  mcub, mcuc, mcuh,   // registered (a clock after the inputs)
	output reg [63:0] analog,
	// the guns' positions on the board's picture (pixels), for the crosshair
	output            guns,
	output reg        g2_on,          // player 2's gun has moved (its crosshair shows)
	output reg [8:0]  g1_x, g2_x,
	output reg [7:0]  g1_y, g2_y
);
	wire [1:0] kind   = mode[1:0];
	wire       drive  = kind == 2'd1 || mode[3];
	assign     guns   = kind == 2'd2 || mode[3];

	function [7:0] clamp(input signed [10:0] v, input [7:0] lo, input [7:0] hi);
		clamp = v < $signed({3'b000, lo}) ? lo : v > $signed({3'b000, hi}) ? hi : v[7:0];
	endfunction
	function [7:0] step_to(input [7:0] v, input [7:0] t, input [7:0] d);
		step_to = v < t ? (t - v > d ? v + d : t) : (v - t > d ? v - d : t);
	endfunction
	wire signed [7:0] sx1 = stick1[7:0], sy1 = stick1[15:8], sx2 = stick2[7:0], sy2 = stick2[15:8];
	wire signed [7:0] ry1 = rstick1[15:8];
	function big(input signed [7:0] v); big = v > 8'sd12 || v < -8'sd12; endfunction

	// ------------------------------------------------------------ per frame
	reg        vb_d;
	wire       tick = vblank && !vb_d;
	reg [7:0]  wheel, accel, brake, hx, hy, lever;
	reg        gear, b3_d;
	// the buttons each mode's pedals use
	wire       b_acc = mode[3] ? p1[5] : p1[4];
	wire       b_brk = mode[3] ? p1[6] : p1[5];
	always @(posedge clk) begin
		vb_d <= vblank; b3_d <= p1[6];
		if (reset) begin
			wheel <= 8'h80; accel <= 8'h00; brake <= 8'h00; hx <= 8'h80; hy <= 8'h80; lever <= 8'h80; gear <= 1'b0;
		end else begin
			if (mode[2] && p1[6] && !b3_d) gear <= !gear;
			if (tick) begin
				// the wheel: the stick, else the d-pad's step
				wheel <= big(sx1) ? clamp(11'sd128 + sx1, 8'h01, 8'hff) :
				         p1[1] ? step_to(wheel, 8'h01, 8'd8) : p1[0] ? step_to(wheel, 8'hff, 8'd8) : step_to(wheel, 8'h80, 8'd8);
				// the pedals: the right stick up / down, else the buttons
				accel <= ry1 < -8'sd12 ? clamp(-ry1, 8'h00, 8'h80) : step_to(accel, b_acc ? 8'h80 : 8'h00, 8'd16);
				brake <= ry1 > 8'sd12 ? clamp(ry1 >>> 1, 8'h00, 8'h40) : step_to(brake, b_brk ? 8'h40 : 8'h00, 8'd8);
				// Metal Hawk: the stick and the lever (B4 up, B5 down)
				hx <= big(sx1) ? clamp(11'sd128 + ((sx1 * 3) >>> 2), 8'h20, 8'he0) :
				      step_to(hx, p1[1] ? 8'h20 : p1[0] ? 8'he0 : 8'h80, 8'd12);
				hy <= big(sy1) ? clamp(11'sd128 + ((sy1 * 3) >>> 2), 8'h20, 8'he0) :
				      step_to(hy, p1[3] ? 8'h20 : p1[2] ? 8'he0 : 8'h80, 8'd12);
				lever <= big(ry1) ? clamp(11'sd128 + ((ry1 * 3) >>> 2), 8'h20, 8'he0) :
				         p1[7] ? step_to(lever, 8'h20, 8'd4) : p1[8] ? step_to(lever, 8'he0, 8'd4) : lever;
			end
		end
	end

	// ------------------------------------------------------------ the guns
	// player 1: the mouse or the stick, whichever moved last; player 2: the stick
	reg  [7:0] m_x = 8'h80, m_y = 8'h80;
	reg        m_t, use_mouse;
	reg [15:0] s1_d;
	wire signed [8:0] mdx = {mouse[4], mouse[15:8]}, mdy = {mouse[5], mouse[23:16]};
	always @(posedge clk) begin
		m_t <= mouse[24];
		s1_d <= stick1;
		if (mouse[24] != m_t) begin
			m_x <= clamp($signed({3'b000, m_x}) + mdx, 8'h00, 8'hff);
			m_y <= clamp($signed({3'b000, m_y}) - mdy, 8'h00, 8'hff);
			if (mdx != 0 || mdy != 0) use_mouse <= 1'b1;
		end
		if (stick1 != s1_d) use_mouse <= 1'b0;
	end
	// positions on the displayed picture, 0-255
	wire [7:0] d1x = use_mouse ? m_x : {~stick1[7], stick1[6:0]};
	wire [7:0] d1y = use_mouse ? m_y : {~stick1[15], stick1[14:8]};
	wire [7:0] d2x = {~stick2[7], stick2[6:0]};
	wire [7:0] d2y = {~stick2[15], stick2[14:8]};
	// on the board's picture
	wire [7:0] n1x = flip ? ~d1x : d1x, n1y = flip ? ~d1y : d1y;
	wire [7:0] n2x = flip ? ~d2x : d2x, n2y = flip ? ~d2y : d2y;
	// the values
	wire [7:0] v1x = mode[6] ? ~n1x : n1x, v1y = mode[6] ? ~n1y : n1y;
	wire [7:0] v2x = mode[6] ? ~n2x : n2x, v2y = mode[6] ? ~n2y : n2y;
	// the crosshairs: 288 x 224 pixels (the products in 12 bits: 255 * 9)
	wire [11:0] g1x_p = {4'd0, n1x} * 12'd9, g2x_p = {4'd0, n2x} * 12'd9;
	wire [11:0] g1y_p = {4'd0, n1y} * 12'd7, g2y_p = {4'd0, n2y} * 12'd7;
	always @(posedge clk) begin
		g1_x <= g1x_p[11:3]; g2_x <= g2x_p[11:3];
		g1_y <= g1y_p[10:3]; g2_y <= g2y_p[10:3];
	end
	always @(posedge clk) if (reset) g2_on <= 1'b0; else if (big(sx2) || big(sy2)) g2_on <= 1'b1;
	wire trig1 = p1[4] || (use_mouse && mouse[0]);
	wire bomb1 = p1[5] || (use_mouse && mouse[1]);

	// ------------------------------------------------------------ the ports
	reg [7:0]  mcub_c, mcuc_c, mcuh_c;
	reg [63:0] analog_c;
	always @(posedge clk) begin mcub <= mcub_c; mcuc <= mcuc_c; mcuh <= mcuh_c; analog <= analog_c; end
	wire trig2 = p2[4], bomb2 = p2[5];
	always @(*) begin
		// MAME's default ports (namcos2.cpp NAMCOS2_MCU_PORT_*_DEFAULT), active low
		mcub_c = ~{start1, start2, p1[3], p2[3], p1[2], p2[2], p1[1], p2[1]};
		mcuc_c = ~{svc1, svc2, coin1, coin2, 4'b0000};
		mcuh_c = ~{p1[0], p2[0], p1[4], p2[4], p1[5], p2[5], p1[6], p2[6]};
		analog_c = an_default;
		if (kind != 2'd0) begin
			mcub_c = idle_b;
			mcuh_c = idle_h;
		end
		if (drive) begin
			analog_c[8 * 5 +: 8] = wheel;
			analog_c[8 * 6 +: 8] = brake;
			analog_c[8 * 7 +: 8] = accel;
			if (mode[2]) mcuh_c[5] = !gear;
		end
		if (kind == 2'd1 && mode[4]) mcub_c[7:6] = ~{start1, start2};
		if (kind == 2'd1 && mode[5]) begin mcub_c[5] = !p1[3]; mcub_c[7] = !p1[2]; end
		if (guns) begin
			case (mode[5:4])
				2'd0: begin analog_c[8 * 0 +: 8] = v1x; analog_c[8 * 1 +: 8] = v1y; analog_c[8 * 2 +: 8] = v2x; analog_c[8 * 3 +: 8] = v2y; end
				2'd1: begin analog_c[8 * 4 +: 8] = v1x; analog_c[8 * 5 +: 8] = v2x; analog_c[8 * 6 +: 8] = v1y; analog_c[8 * 7 +: 8] = v2y; end
				default: begin analog_c[8 * 4 +: 8] = v1x; analog_c[8 * 2 +: 8] = v1y; analog_c[8 * 3 +: 8] = v2x; analog_c[8 * 1 +: 8] = v2y; end
			endcase
			mcub_c[7:6] = ~{start1, start2};
			if (mode[7]) mcub_c[5:4] = ~{trig1, trig2};
			else begin
				mcuh_c[5:4] = ~{trig1, trig2};
				if (!mode[3]) mcuh_c[3:2] = ~{bomb1, bomb2};
			end
		end
		if (kind == 2'd3) begin
			analog_c[8 * 5 +: 8] = hy;
			analog_c[8 * 6 +: 8] = hx;
			analog_c[8 * 7 +: 8] = lever;
			mcub_c[7:6] = ~{start1, start2};
			mcuh_c[5] = !p1[4];   // B1
			mcuh_c[7] = !p1[5];   // B2
		end
	end
endmodule
