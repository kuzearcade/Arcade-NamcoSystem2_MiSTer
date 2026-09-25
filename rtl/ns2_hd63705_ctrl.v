// Derived from jt6805 (jotego/jtcores modules/jt680x @ 3eb8fec, GPL-3.0-or-later,
// rtl/third_party/jt680x) for the C65's HD63705Z0 as MAME implements it
// (hd6305.cpp, docs/PLAN.md D2): 16-bit addresses; the stack in page 1
// (0x100-0x17f, 7 bits); vectors at 0x1fe0 + 2 * iv with a 4-bit iv (reset
// 15 = 0x1ffe, SWI 14 = 0x1ffc, IRQ1 12 = 0x1ff8, A/D conversion 5 = 0x1fea).
// The microcode (6805.yaml) is jt6805's.
/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 4-12-2023 */
/* verilator coverage_off */
module ns2_hd63705_ctrl(
    input        rst,
    input        clk,
    input        cen,
    input [15:0] md,
    // interrupts
    input        i,
    input        irq,     // IRQ1 (latched by the wrapper)
    input        adc,     // the A/D conversion interrupt (latched)
    output reg [3:0] iv,
    // control
    output       branch,
    output       brlatch,
    output       fetch,
    output       inc_pc,
    output       md_shift,
    output       op0inv,
    output       stop,
    output       wr,
    output [1:0] brt_sel,
    output [1:0] carry_sel,
    output [1:0] ea_sel,
    output [1:0] opnd_sel,
    output [2:0] ld_sel,
    output [3:0] alu_sel,
    output [3:0] cc_sel,
    output [3:0] rmux_sel
);

`include "6805_param.vh"
`include "6805.vh"

wire [4:0] jsr_sel;
reg  [3:0] iv_sel;
wire       halt, swi, ni;
wire [3:0] nx_ualo = uaddr[3:0] + 1'd1;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        uaddr   <= IVRD_SEQA;
        jsr_ret <= 0;
        iv      <= 15;
    end else if(cen) begin
        if(~halt&~stop) uaddr[3:0] <= nx_ualo;
        if( swi ) iv <= 14;
        if( ni | halt | stop) begin
            uaddr <= { md[7:0], 4'd0 };
            if( ~i ) begin
                // MAME's order: IRQ1 before the A/D interrupt
                if( irq ) begin
                    iv     <= 12;
                    uaddr  <= ISRV_SEQA; // irq service
                end else if( adc ) begin
                    iv    <= 5;
                    uaddr <= ISRV_SEQA;
                end
            end
        end
        if( jsr_en ) begin
            jsr_ret <= uaddr;
            jsr_ret[3:0] <= nx_ualo;
            uaddr   <= jsr_ua;
        end
    end
end

endmodule