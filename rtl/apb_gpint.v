// =============================================================
// File:        rtl/apb_gpint.v
// Module:      apb_gpint
// Role:        AE350 の GP_INT (= ユーザーの割り込み 16 本) を、APB のレジスタから立てる回路 (= 段 4、2026-11-10)。
//              FPGA のロジック側の回路で、実機にもそのまま載る。
//
// Registers (= PADDR[3:2] で選ぶ。上位のビットは見ない):
//   0x00  GP_INT   R/W   下位 16 bit をそのまま GP_INT[15:0] に出す (= レベル)。初期値 0
//   それ以外       PSLVERR = 1 を返す
//
// Ports:
//   input  wire        clk / rst_n
//   input  wire        psel / penable / pwrite
//   input  wire [31:0] paddr / pwdata
//   input  wire [3:0]  pstrb       書き込みは pstrb のバイトレーンだけ (= 下位 2 byte)
//   output wire [31:0] prdata
//   output wire        pready / pslverr
//   output wire [15:0] gp_int
//
// Clock:       clk (= APB_CLK と同じクロック)
// Reset:       rst_n (active low、非同期)
// =============================================================

`default_nettype none

module apb_gpint (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output reg  [15:0] gp_int
);

    wire reg_known = (paddr[3:2] == 2'd0);
    wire access    = psel && penable;

    assign pready  = 1'b1;
    assign pslverr = access && !reg_known;
    assign prdata  = reg_known ? {16'd0, gp_int} : 32'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gp_int <= 16'd0;
        end else if (access && pwrite && reg_known) begin
            if (pstrb[0]) gp_int[7:0]  <= pwdata[7:0];
            if (pstrb[1]) gp_int[15:8] <= pwdata[15:8];
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{paddr[31:4], paddr[1:0], pwdata[31:16], pstrb[3:2]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
