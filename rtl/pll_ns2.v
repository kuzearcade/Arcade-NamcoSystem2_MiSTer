// The core's PLL (docs/PLAN.md 2.2), from the 50 MHz reference:
//   outclk_0  49.152 MHz  clk_sys: the board (fx68k phases /2, the pixel /8)
//   outclk_1  98.304 MHz  clk_sd:  jtframe_sdram64 and CLK_VIDEO
//   outclk_2  98.304 MHz, 2.54 ns early: the SDRAM chip's clock (SDRAM_CLK,
//             through an altddio_out). jtframe_sdram64 launches a command
//             on an edge for the chip to take on the next, and takes read
//             data on the edge after the chip drives it; with Cyclone V's
//             pin delays that leaves the chip's clock a window of about
//             -4 to +2 ns around the controller's.
// Fractional: 49.152 / 50 is 3072 / 3125. The template is Quartus's own
// altera_pll instance (as the MiSTer cores' rtl/pll/pll_0002.v).
`timescale 1ns/10ps
module pll_ns2 (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);
	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("49.152000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("98.304000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		// 270 degrees (-2.54 ns): the VCO runs at 491.6 MHz and a phase is
		// a multiple of an eighth of its period (254.3 ps), 30 of them here
		.output_clock_frequency2("98.304000 MHz"),
		.phase_shift2("7628 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"), .phase_shift3("0 ps"), .duty_cycle3(50),
		.output_clock_frequency4("0 MHz"), .phase_shift4("0 ps"), .duty_cycle4(50),
		.output_clock_frequency5("0 MHz"), .phase_shift5("0 ps"), .duty_cycle5(50),
		.output_clock_frequency6("0 MHz"), .phase_shift6("0 ps"), .duty_cycle6(50),
		.output_clock_frequency7("0 MHz"), .phase_shift7("0 ps"), .duty_cycle7(50),
		.output_clock_frequency8("0 MHz"), .phase_shift8("0 ps"), .duty_cycle8(50),
		.output_clock_frequency9("0 MHz"), .phase_shift9("0 ps"), .duty_cycle9(50),
		.output_clock_frequency10("0 MHz"), .phase_shift10("0 ps"), .duty_cycle10(50),
		.output_clock_frequency11("0 MHz"), .phase_shift11("0 ps"), .duty_cycle11(50),
		.output_clock_frequency12("0 MHz"), .phase_shift12("0 ps"), .duty_cycle12(50),
		.output_clock_frequency13("0 MHz"), .phase_shift13("0 ps"), .duty_cycle13(50),
		.output_clock_frequency14("0 MHz"), .phase_shift14("0 ps"), .duty_cycle14(50),
		.output_clock_frequency15("0 MHz"), .phase_shift15("0 ps"), .duty_cycle15(50),
		.output_clock_frequency16("0 MHz"), .phase_shift16("0 ps"), .duty_cycle16(50),
		.output_clock_frequency17("0 MHz"), .phase_shift17("0 ps"), .duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst(rst),
		.outclk({outclk_2, outclk_1, outclk_0}),
		.locked(locked),
		.fboutclk(),
		.fbclk(1'b0),
		.refclk(refclk)
	);
endmodule
