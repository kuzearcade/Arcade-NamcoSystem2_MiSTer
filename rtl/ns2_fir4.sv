// A sound chip's anti-imaging interpolator (NS2-26, NS2-29): its samples
// (one per in_stb) out at 4x through a 128-tap low-pass whose passband is
// MAME's own resampler's response (tools/ns2_firgen.py): a held sample puts
// images above the chip's Nyquist, which MAME's resampler removes.
//   CHIP 0: the C140, 21.333 kHz (every 2304 clocks), SPACE 576;
//            rtl/ns2_c140_fir_coef.vh
//   CHIP 1: the YM2151 (jt51), 55.93 kHz (every 878-879 clocks), SPACE 219;
//            rtl/ns2_ym_fir_coef.vh
//
// An input sample starts four phases, SPACE clocks apart. Phase p's output
// is sum_k coef(4k + p) * x[n - k], k = 0..31, both channels at once (two
// multipliers), a tap a clock; the output holds until the next phase.
module ns2_fir4 #(parameter CHIP = 0, parameter [11:0] SPACE = 12'd576) (
	input                    clk,
	input                    reset,
	input                    in_stb,
	input      signed [15:0] in_l,
	input      signed [15:0] in_r,
	output reg signed [15:0] out_l,
	output reg signed [15:0] out_r
);
	`include "ns2_c140_fir_coef.vh"
	`include "ns2_ym_fir_coef.vh"

	reg signed [15:0] hl [0:31];
	reg signed [15:0] hr [0:31];
	reg  [4:0]  wp;            // the newest sample's slot
	reg  [11:0] t;             // clocks since the input sample
	reg  [1:0]  ph;            // the phase being computed
	reg         run;
	reg  [5:0]  k;             // the tap (32 = done)
	// the pipeline: the tap's operands, the products, the sums
	reg signed [15:0] xl, xr;
	reg signed [17:0] c;
	reg               v1, v2;
	reg signed [33:0] pl, pr;
	reg signed [39:0] al, ar;
	reg               fin1, fin2, fin3;
	reg               first1, first2;    // a phase's first tap, through the pipeline

	function signed [15:0] sat(input signed [39:0] v);
		sat = (v >>> 17) > 40'sd32767 ? 16'sh7fff : (v >>> 17) < -40'sd32768 ? -16'sh8000 : 16'(v >>> 17);
	endfunction

	always @(posedge clk) begin
		if (reset) begin
			wp <= 0; t <= 0; ph <= 0; run <= 1'b0; k <= 6'd32; v1 <= 1'b0; v2 <= 1'b0;
			fin1 <= 1'b0; fin2 <= 1'b0; fin3 <= 1'b0; out_l <= 0; out_r <= 0; al <= 0; ar <= 0;
		end else begin
			// the schedule: phases at 0, 576, 1152, 1728 clocks after a sample
			if (in_stb) begin
				hl[wp + 5'd1] <= in_l; hr[wp + 5'd1] <= in_r; wp <= wp + 5'd1;
				t <= 0; ph <= 0; k <= 0;
			end else begin
				if (t != 12'hfff) t <= t + 1'd1;
				if (t == SPACE - 1'd1 || t == 2 * SPACE - 1'd1 || t == 3 * SPACE - 1'd1) begin ph <= ph + 1'd1; k <= 0; end
			end
			// stage 1: a tap's operands
			v1 <= k < 6'd32;
			if (k < 6'd32) begin
				xl <= hl[wp - k[4:0]]; xr <= hr[wp - k[4:0]];
				c  <= CHIP == 1 ? coef_ym({k[4:0], ph}) : coef_c140({k[4:0], ph});
				k  <= k + 1'd1;
			end
			fin1 <= k == 6'd31;
			first1 <= k == 6'd0;
			// stage 2: the products
			v2 <= v1; fin2 <= fin1; first2 <= first1;
			pl <= xl * c; pr <= xr * c;
			// stage 3: the sums (restarting at a phase's first tap)
			fin3 <= fin2;
			if (v2) begin
				al <= (first2 ? 40'sd0 : al) + 40'(pl);
				ar <= (first2 ? 40'sd0 : ar) + 40'(pr);
			end
			if (fin3) begin out_l <= sat(al); out_r <= sat(ar); end
		end
	end
endmodule
