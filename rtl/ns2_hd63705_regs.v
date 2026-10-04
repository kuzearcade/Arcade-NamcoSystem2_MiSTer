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
module ns2_hd63705_regs(
    input             rst,
    input             clk,
    input             cen,
    output reg [15:0] md,
    // interrupts
    input      [ 3:0] iv,
    input             irq,
    // CONTROL
    input             branch,
    input             brlatch,
    input             fetch,
    input             inc_pc,
    input             md_shift,
    input             op0inv,
    input             wr,
    input      [ 1:0] brt_sel,
    input      [ 1:0] ea_sel,
    input      [ 1:0] opnd_sel,
    input      [ 2:0] ld_sel,
    input      [ 3:0] cc_sel,
    input      [ 3:0] rmux_sel,
    // ALU
    input      [15:0] rslt,
    input             rslt_h,
    input      [ 2:0] rslt_cc,
    output reg [15:0] op0, op1,
    output reg        h,c,i,
    // external bus
    input      [ 7:0] din,
    output reg [15:0] addr, // always valid
    output reg [ 7:0] dout,
    // the savestate (NS2 M5): 2 {a, x}, 3 {s, h, i, n, z, c, brok}, 4 pc,
    // 5 ea, 6 md, 7 op0, 8 op1
    input      [ 3:0] ss_sel,
    input             ss_wr,
    input      [15:0] ss_wdata,
    output reg [15:0] ss_rdata
);

`include "63705_param.vh"

reg  [ 7:0] a, x;
reg  [ 6:0] s;
reg  [15:0] rmux, ea, pc;
reg         n,z; // other condition codes
reg         brok;

`ifdef SIMULATION
wire [4:0] cc = {h,i,n,z,c};
`endif

always @* begin
    case( rmux_sel )
           A_RMUX: rmux = { 8'd0, a };
           X_RMUX: rmux = { 8'd0, x };
           S_RMUX: rmux = { 9'd2, s };        // 0x100 | s
          PC_RMUX: rmux = pc;
          EA_RMUX: rmux = ea;
          CC_RMUX: rmux = {11'd0, h,i,n,z,c};
         ONE_RMUX: rmux = 16'd1;
        ZERO_RMUX: rmux = 16'd0;
          IV_RMUX: rmux = {11'h0ff,iv,1'b0};  // 0x1fe0 + 2 * iv
          default: rmux = md;
    endcase
    case( ea_sel )
        S_EA: addr = { 9'd2, s };
        M_EA: addr = ea;
        default: addr = pc;
    endcase
    dout = md_shift ? md[15:8] : md[7:0];
end

always @( posedge clk, posedge rst ) begin
    if( rst ) begin
        a   <= 0;
        x   <= 0;
        s   <= 7'h7f;
        op0 <= 0;
        op1 <= 0;
        md  <= 0;
        ea  <= 0;
        {h,n,z,c} <= 0;
        i    <= 1;
    end else if( ss_wr ) begin
        case( ss_sel )
            4'd2: {a, x} <= ss_wdata;
            4'd3: {s, h, i, n, z, c} <= ss_wdata[12:1];
            4'd4: pc  <= ss_wdata;
            4'd5: ea  <= ss_wdata;
            4'd6: md  <= ss_wdata;
            4'd7: op0 <= ss_wdata;
            4'd8: op1 <= ss_wdata;
            default:;
        endcase
    end else if( cen ) begin
        if( fetch  ) begin
            md[ 7:0] <= din;
            md[15:8] <= md_shift ? md[7:0] : 8'd0;
        end
        if( branch ) md[15:8] <= {8{md[7]}}; // sign extension for BR instructions
        case( opnd_sel )
            LD0_OPND: op0 <= {16{op0inv}} ^ rmux;
            LD1_OPND: op1 <= rmux;
            default:;
        endcase
        case( cc_sel )
              NZ_CC:    {n,z  } <= rslt_cc[2:1];
             NZC_CC:    {n,z,c} <= rslt_cc;
            NZC1_CC:    {n,z,c} <= {rslt_cc[2:1],1'b1};
            N0Z1_CC:    {n,z  } <= 2'b01;
              I0_CC:  i         <= 0;
              I1_CC:  i         <= 1;
            HNZC_CC:  {h,n,z,c} <= {rslt_h, rslt_cc};
               C_CC:         c  <= rslt_cc[0];
              C0_CC:         c  <= 0;
              C1_CC:         c  <= 1;
            default:;
        endcase
        case( ld_sel )
              A_LD:     a <= rslt[7:0];
              X_LD:     x <= rslt[7:0];
              S_LD:     s <= rslt[6:0];
             MD_LD:    md <= rslt;
             EA_LD:    ea <= rslt;
             CC_LD:    {h,i,n,z,c} <= rslt[4:0];
             PC_LD: if( (brok && branch) || (!branch && brt_sel==0) || (brt_sel==CLR_BRT && !c) || (brt_sel==SET_BRT && c))
                        pc <= rslt;
             default:;
        endcase
        if( inc_pc ) pc <= pc+16'd1;
    end
end

always @* begin
    case( ss_sel )
        4'd2: ss_rdata = {a, x};
        4'd3: ss_rdata = {3'd0, s, h, i, n, z, c, brok};
        4'd4: ss_rdata = pc;
        4'd5: ss_rdata = ea;
        4'd6: ss_rdata = md;
        4'd7: ss_rdata = op0;
        default: ss_rdata = op1;
    endcase
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        brok <= 0;
    end else if( ss_wr && ss_sel == 4'd3 ) begin
        brok <= ss_wdata[0];
    end else if(cen) begin
        if( brlatch ) case(md[3:0])
            4'b0000: brok <= 1; // bra
            4'b0001: brok <= 0; // brn
            4'b0010: brok <= !(c | z); // bhi
            4'b0011: brok <=   c | z;  // bls
            4'b0100: brok <= ! c; // bcc/bhs
            4'b0101: brok <=   c; // bcs/blo
            4'b0110: brok <= ! z; // bne
            4'b0111: brok <=   z; // beq
            4'b1000: brok <= ! h; // bhc
            4'b1001: brok <=   h; // bhs
            4'b1010: brok <= ! n; // bpl
            4'b1011: brok <=   n; // bmi
            4'b1100: brok <= ! i; // bmc
            4'b1101: brok <=   i; // bms
            4'b1110: brok <= irq; // int. line active
            4'b1111: brok <=~irq; // int. line clear
        endcase
    end
end

endmodule