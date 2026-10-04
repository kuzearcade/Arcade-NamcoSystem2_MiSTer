// Derived from jt6805 (jotego/jtcores modules/jt680x @ 3eb8fec, GPL-3.0-or-later,
// rtl/third_party/jt680x) for the C65's HD63705Z0 as MAME implements it
// (hd6305.cpp, docs/PLAN.md D2): 16-bit addresses; the stack in page 1
// (0x100-0x17f, 7 bits); vectors at 0x1fe0 + 2 * iv with a 4-bit iv (reset
// 15 = 0x1ffe, SWI 14 = 0x1ffc, IRQ1 12 = 0x1ff8, A/D conversion 5 = 0x1fea).
// The microcode (6805.yaml) is jt6805's.
/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 22-11-2023 */

`ifndef VERILATOR_KEEP_CPU
/* verilator tracing_off */
`endif
/* verilator coverage_off */

module ns2_hd63705(
    input             rst,
    input             clk,
    input             cen,  // crystal clock freq. = 4x E pin freq.
    input             irq,  // IRQ1 (latched: cleared by irq_ack)
    input             adc,  // the A/D conversion interrupt (latched)
    output            wr,
    output            rd,   // the microcode's data load this clock (a read of addr)
    output            tstop,// timer stop
    output     [15:0] addr, // always valid
    input      [ 7:0] din,
    output     [ 7:0] dout,
    // the savestate (NS2 M5): every flop, a word each (0-1 the sequencer,
    // 2-8 the registers); a write replaces it (cen off)
    input      [ 3:0] ss_sel,
    input             ss_wr,
    input      [15:0] ss_wdata,
    output     [15:0] ss_rdata
);
wire [15:0] ss_cq, ss_rq;
assign ss_rdata = ss_sel < 4'd2 ? ss_cq : ss_rq;

wire [15:0] op0, op1, rslt,md;
wire [ 2:0] rslt_cc;
wire [ 3:0] iv;
wire        h, rslt_h, c, i;

wire [3:0] alu_sel;
wire [1:0] brt_sel;
wire [3:0] cc_sel;
wire [1:0] ea_sel;
wire [2:0] ld_sel;
wire [1:0] opnd_sel;
wire [1:0] carry_sel;
wire [3:0] rmux_sel;

wire       branch;
wire       brlatch;
wire       fetch;
wire       op0inv;
wire       inc_pc;
wire       md_shift;
wire       swi;
assign rd = fetch;

ns2_hd63705_ctrl u_ctrl(
    .ss_sel(ss_sel), .ss_wr(ss_wr && ss_sel < 4'd2), .ss_wdata(ss_wdata), .ss_rdata(ss_cq),
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .md         ( md        ),
    // interrupt
    .irq        ( irq       ),
    .adc        ( adc       ),
    .i          ( i         ),
    .iv         ( iv        ),
    // control
    .branch     ( branch    ),
    .brlatch    ( brlatch   ),
    .fetch      ( fetch     ),
    .inc_pc     ( inc_pc    ),
    .md_shift   ( md_shift  ),
    .op0inv     ( op0inv    ),
    .stop       ( tstop     ),
    .wr         ( wr        ),
    .brt_sel    ( brt_sel   ),
    .carry_sel  ( carry_sel ),
    .ea_sel     ( ea_sel    ),
    .opnd_sel   ( opnd_sel  ),
    .ld_sel     ( ld_sel    ),
    .alu_sel    ( alu_sel   ),
    .cc_sel     ( cc_sel    ),
    .rmux_sel   ( rmux_sel  )
);

ns2_hd63705_alu u_alu(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .carry_sel  ( carry_sel ),
    .alu_sel    ( alu_sel   ),
    .cin        ( c         ),
    .hin        ( h         ),
    .op0        ( op0       ),
    .op1        ( op1       ),
    .ho         ( rslt_h    ),
    .rslt       ( rslt      ),
    .rslt_cc    ( rslt_cc   )
);

ns2_hd63705_regs u_regs(
    .ss_sel(ss_sel), .ss_wr(ss_wr && ss_sel >= 4'd2), .ss_wdata(ss_wdata), .ss_rdata(ss_rq),
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .md         ( md        ),
    .branch     ( branch    ),
    .brlatch    ( brlatch   ),
    .fetch      ( fetch     ),
    .inc_pc     ( inc_pc    ),
    .md_shift   ( md_shift  ),
    .op0inv     ( op0inv    ),
    .wr         ( wr        ),
    .brt_sel    ( brt_sel   ),
    .ea_sel     ( ea_sel    ),
    .opnd_sel   ( opnd_sel  ),
    .ld_sel     ( ld_sel    ),
    .cc_sel     ( cc_sel    ),
    .rmux_sel   ( rmux_sel  ),
    // interrupts
    .irq        ( irq       ),
    .i          ( i         ),
    .iv         ( iv        ),
    // ALU
    .rslt       ( rslt      ),
    .rslt_h     ( rslt_h    ),
    .rslt_cc    ( rslt_cc   ),
    .op0        ( op0       ),
    .op1        ( op1       ),
    .h          ( h         ),
    .c          ( c         ),
    .din        ( din       ),
    .addr       ( addr      ),
    .dout       ( dout      )
);

endmodule