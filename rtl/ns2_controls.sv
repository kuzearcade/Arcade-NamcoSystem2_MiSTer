// The players' controls onto the I/O MCU's ports (namcos2.cpp's input
// ports): the digital ports MCUB, MCUC, MCUH and the eight analog channels
// AN0-AN7, per the set's control mode (config byte 33, tools/ns2_romdata.py):
//   [1:0] 0 digital (MAME's default ports), 1 wheel and pedals, 2 light
//         guns, 3 Metal Hawk's analog stick
//   [2]   digital: Assault's twin sticks (below); wheel: the gear shift is
//         a toggle on MCUH bit 5 (B3: Final Lap, Four Trax)
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
	input      [3:0]  rp1, rp2,       // Assault's right stick as buttons: [0] U [1] D [2] L [3] R
	input             start1, start2, coin1, coin2, svc1, svc2,
	input      [15:0] stick1, stick2, // left sticks {Y, X}, signed; a light gun's position
	input      [15:0] rstick1, rstick2, // the right sticks {Y, X}
	input      [31:0] dial_default,   // MAME's power-on MCUDI0-3 (config bytes 29-32)
	input      [24:0] mouse,          // ps2_mouse: [24] toggles per packet, [15:8] dx, [23:16] dy, [0] L [1] R
	output reg [7:0]  mcub, mcuc, mcuh,   // registered (a clock after the inputs)
	output reg [63:0] analog,
	output reg [31:0] dials,          // MCUDI0-3 ($3000-$3003)
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
	// Each gun aims from the stick (or a MiSTer gun), the d-pad (8 a frame,
	// MAME's key delta; it stays where it is left), or for player 1 the
	// mouse: whichever moved last. Lucky & Wild's player 1 steers with the
	// d-pad, so aims from the stick or the mouse. A stick takes over from
	// the d-pad only when pushed (a resting stick's noise does not).
	localparam [1:0] SRC_STICK = 2'd0, SRC_MOUSE = 2'd1, SRC_PAD = 2'd2;
	reg  [7:0] m_x = 8'h80, m_y = 8'h80;
	reg  [7:0] k1x = 8'h80, k1y = 8'h80, k2x = 8'h80, k2y = 8'h80;
	reg  [1:0] src1 = SRC_STICK, src2 = SRC_STICK;
	reg        m_t;
	reg [15:0] s1_d, s2_d;
	wire       pad1_ok = !mode[3];
	wire       pad1 = pad1_ok && |p1[3:0], pad2 = |p2[3:0];
	wire signed [8:0] mdx = {mouse[4], mouse[15:8]}, mdy = {mouse[5], mouse[23:16]};
	function [7:0] pad_step(input [7:0] v, input dec, input inc);
		pad_step = dec ? (v < 8'd8 ? 8'd0 : v - 8'd8) : inc ? (v > 8'd247 ? 8'd255 : v + 8'd8) : v;
	endfunction
	always @(posedge clk) begin
		m_t <= mouse[24];
		s1_d <= stick1;
		s2_d <= stick2;
		if (tick) begin
			if (pad1_ok) begin k1x <= pad_step(k1x, p1[1], p1[0]); k1y <= pad_step(k1y, p1[3], p1[2]); end
			k2x <= pad_step(k2x, p2[1], p2[0]); k2y <= pad_step(k2y, p2[3], p2[2]);
		end
		if (mouse[24] != m_t) begin
			m_x <= clamp($signed({3'b000, m_x}) + mdx, 8'h00, 8'hff);
			m_y <= clamp($signed({3'b000, m_y}) - mdy, 8'h00, 8'hff);
		end
		// the last to move aims (later lines win within a clock)
		if (stick1 != s1_d && (src1 != SRC_PAD || big(sx1) || big(sy1))) src1 <= SRC_STICK;
		if (mouse[24] != m_t && (mdx != 0 || mdy != 0)) src1 <= SRC_MOUSE;
		if (pad1) src1 <= SRC_PAD;
		if (stick2 != s2_d && (big(sx2) || big(sy2))) src2 <= SRC_STICK;
		if (pad2) src2 <= SRC_PAD;
		if (reset) begin
			src1 <= SRC_STICK; src2 <= SRC_STICK;
			m_x <= 8'h80; m_y <= 8'h80; k1x <= 8'h80; k1y <= 8'h80; k2x <= 8'h80; k2y <= 8'h80;
		end
	end
	wire       use_mouse = src1 == SRC_MOUSE;
	// positions on the displayed picture, 0-255
	wire [7:0] d1x = use_mouse ? m_x : src1 == SRC_PAD ? k1x : {~stick1[7], stick1[6:0]};
	wire [7:0] d1y = use_mouse ? m_y : src1 == SRC_PAD ? k1y : {~stick1[15], stick1[14:8]};
	wire [7:0] d2x = src2 == SRC_PAD ? k2x : {~stick2[7], stick2[6:0]};
	wire [7:0] d2y = src2 == SRC_PAD ? k2y : {~stick2[15], stick2[14:8]};
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
	always @(posedge clk) if (reset) g2_on <= 1'b0; else if (big(sx2) || big(sy2) || pad2) g2_on <= 1'b1;
	wire trig1 = p1[4] || (use_mouse && mouse[0]);
	wire bomb1 = p1[5] || (use_mouse && mouse[1]);

	// ------------------------------------------------------------ Assault
	// Two 4-way sticks a player, a tank's two tracks (MAME's assault ports):
	// the left on MCUB (up, down, left) and MCUH 7/6 (right), the right on
	// MCUH (up, down) and MCUDI0 (right, left). The analog sticks drive them
	// one each. MiSTer also presses the d-pad from the left analog stick,
	// and sends a pad's analog sticks only when its mapping marks them
	// analog: without, the left stick reaches the core as the d-pad alone,
	// and the right not at all. So the right stick can also be four buttons
	// (B6-B9, rp: a stick's directions can be bound to them). A player who
	// has used the right stick (analog or buttons, `tw` since reset) drives
	// the left track with the left analog stick or the d-pad and the right
	// with the right stick. Until then the left analog stick drives the
	// left track, and the d-pad (with no analog stick pushed) both alike:
	// forward, back, sideways. B3 and B4 turn (left track back and right
	// forward, and the reverse); B2 and B5 push the sticks apart and
	// together. {U, D, L, R} each.
	function [3:0] dir4(input signed [7:0] x, input signed [7:0] y);
		reg [7:0] ax, ay;
		begin
			ax = x[7] ? -x : x; ay = y[7] ? -y : y;
			if (!big(x) && !big(y)) dir4 = 4'b0000;
			else if (ay >= ax) dir4 = y[7] ? 4'b1000 : 4'b0100;
			else dir4 = x[7] ? 4'b0010 : 4'b0001;
		end
	endfunction
	// the d-pad, 4-way: up / down before left / right
	function [3:0] pad4(input [3:0] udlr);
		pad4 = udlr[3] ? 4'b1000 : udlr[2] ? 4'b0100 : udlr[1] ? 4'b0010 : udlr[0] ? 4'b0001 : 4'b0000;
	endfunction
	function [7:0] twin(input [8:0] p, input [3:0] rp, input tw, input [15:0] ls, input [15:0] rs);   // {left, right}
		reg [3:0] al, ar, pd, pr;
		begin
			al = dir4(ls[7:0], ls[15:8]); ar = dir4(rs[7:0], rs[15:8]); pd = pad4(p[3:0]);
			pr = pad4({rp[0], rp[1], rp[2], rp[3]});
			if (tw) twin = {al != 0 ? al : pd, ar != 0 ? ar : pr};
			else    twin = (al != 0 || ar != 0) ? {al, ar} : {pd, pd};
			if (p[6]) twin = {4'b0100, 4'b1000};        // B3: turn left
			if (p[7]) twin = {4'b1000, 4'b0100};        // B4: turn right
			if (p[5]) twin = {4'b0010, 4'b0001};        // B2: apart
			if (p[8]) twin = {4'b0001, 4'b0010};        // B5: together
		end
	endfunction
	// a player's right stick in use (analog past the 4-way threshold, or B6-B9)
	reg tw1, tw2;
	always @(posedge clk)
		if (reset) begin tw1 <= 1'b0; tw2 <= 1'b0; end
		else begin
			if (rp1 != 0 || dir4(rstick1[7:0], rstick1[15:8]) != 0) tw1 <= 1'b1;
			if (rp2 != 0 || dir4(rstick2[7:0], rstick2[15:8]) != 0) tw2 <= 1'b1;
		end
	wire [7:0] t1 = twin(p1, rp1, tw1, stick1, rstick1), t2 = twin(p2, rp2, tw2, stick2, rstick2);
	wire [3:0] l1 = t1[7:4], r1 = t1[3:0], l2 = t2[7:4], r2 = t2[3:0];

	// ------------------------------------------------------------ the ports
	reg [7:0]  mcub_c, mcuc_c, mcuh_c;
	reg [63:0] analog_c;
	reg [31:0] dials_c;
	always @(posedge clk) begin mcub <= mcub_c; mcuc <= mcuc_c; mcuh <= mcuh_c; analog <= analog_c; dials <= dials_c; end
	wire trig2 = p2[4], bomb2 = p2[5];
	always @(*) begin
		// MAME's default ports (namcos2.cpp NAMCOS2_MCU_PORT_*_DEFAULT), active low
		mcub_c = ~{start1, start2, p1[3], p2[3], p1[2], p2[2], p1[1], p2[1]};
		mcuc_c = ~{svc1, svc2, coin1, coin2, 4'b0000};
		mcuh_c = ~{p1[0], p2[0], p1[4], p2[4], p1[5], p2[5], p1[6], p2[6]};
		analog_c = an_default;
		dials_c  = dial_default;
		if (kind == 2'd0 && mode[2]) begin
			// Assault: {U, D, L, R} = [3:0] of each stick
			mcub_c = ~{start1, start2, l1[3], l2[3], l1[2], l2[2], l1[1], l2[1]};
			mcuh_c = ~{l1[0], l2[0], p1[4], p2[4], r1[3], r2[3], r1[2], r2[2]};
			dials_c[3:0] = ~{r1[1], r2[1], r1[0], r2[0]};
		end
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
