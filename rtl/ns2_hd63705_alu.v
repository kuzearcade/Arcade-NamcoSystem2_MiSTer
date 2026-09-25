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
module ns2_hd63705_alu(
    input          rst,
    input          clk,
    input          cen,
    input   [ 1:0] carry_sel,
    input   [ 3:0] alu_sel,
    input          cin,
    input          hin,
    input   [15:0] op0, op1,

    output reg        ho,
    output reg [15:0] rslt,
    output     [ 2:0] rslt_cc
);

`include "63705_param.vh"

wire [3:0] bsel;
reg  c8, cx, n8, z8;

assign rslt_cc = {n8,z8,c8};
assign bsel    = {1'b0,op1[3:1]};

always @* begin
    case( carry_sel )
        CIN_CARRY: cx = cin;
        MSB_CARRY: cx = op0[7];
        default:   cx = 0;
    endcase

    rslt = op0;
    c8   = 0;
    ho   = 0;
    case( alu_sel )
        ADD_ALU: begin
            {ho,  rslt[ 3:0]} = {1'b0, op0[ 3:0]}+{1'b0, op1[ 3:0]}+{4'd0,cx};
            {c8,  rslt[ 7:4]} = {1'b0, op0[ 7:4]}+{1'b0, op1[ 7:4]}+{4'd0,ho};
            rslt[15:8] = op0[15:8]+op1[15:8]+{7'd0,c8};
        end
        SUB_ALU: {c8,rslt[7:0]} = {1'b0, op0[7:0]}-{1'b0,op1[7:0]}-{8'b0,cx};
        AND_ALU: rslt[7:0] = op0[7:0] & op1[7:0];
         OR_ALU: rslt[7:0] = op0[7:0] | op1[7:0];
        EOR_ALU: rslt[7:0] = op0[7:0] ^ op1[7:0];
        LSR_ALU: {rslt[7:0],c8} = {cx,op0[7:0]};
        LSL_ALU: {c8,rslt[7:0]} = {op0[7:0],cx};
        BSET_ALU: begin
            rslt[7:0] = op0[7:0];
            rslt[bsel]=1;
            c8=op0[bsel];
        end
        BCLR_ALU: begin
            rslt[7:0] = op0[7:0];
            rslt[bsel]=0;
            c8=op0[bsel];
        end
        default: rslt = op0;
    endcase

    z8 = rslt[7:0]==0;
    n8 = rslt[7];
end

endmodule