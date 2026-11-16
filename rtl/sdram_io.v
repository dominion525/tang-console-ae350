// =============================================================
// File:        rtl/sdram_io.v
// Module:      sdram_io
// Role:        SDR SDRAM (W9825G6KH) のピン周りの回路。166.7 MHz 版の SDRAM コントローラで使う。
//              すべてのピンを IO 内のレジスタ (Gowin の ODDR と IDDR) で入出力し、ピンでのタイミングを揃える。
//              1 本のピンの ODDR と IDDR は同じクロックで動かす必要がある (合成の CK0012) ので、どちらも s_clk で動かす。
//              読み出しデータを取り込むタイミングは、IO 内の遅延素子 (IODELAY) と、取り込むエッジ (立ち上がりか立ち下がりか) で決める。
//
//   コマンド、アドレス、DQM  ODDR (D0 = D1) で、s_clk の立ち上がりから出力する
//   DQ の出力と出力許可      ODDR の Q0 (値) と Q1 (IOBUF の OEN。1 で出力しない) で、同じ遅延で出力する
//   DQ の入力                ピン → IODELAY (IN_DLY × 約 12.5 ps) → IDDR。CAP_EDGE が 0 なら立ち上がりで取り込んだ Q0、
//                           1 なら立ち下がりで取り込んだ Q1 を、s_clk でもう 1 段受けて dq_in に出力する
//   SDRAM のクロック         ODDR (D0 = 0、D1 = 1) で s_clk を反転して出力する。SDRAM は、コマンドが変わるエッジの
//                           半周期後にコマンドを取り込む
//
//   遅延 (Gowin のプリミティブのモデルに従う。tb/gowin_io_models.v):
//     出力: s_clk のエッジ n で入れた値が、エッジ n + 2 からピンに出る (コマンドも DQ も同じ 2 サイクル)
//     入力: 立ち上がり m で取り込んだ値はエッジ m + 3 の後に、立ち下がり m - 0.5 で取り込んだ値はエッジ m + 2 の後に
//           dq_in に出る (IDDR の内部で、立ち下がり側は 1 段短い)
//
// Parameters:
//   IN_DLY     DQ の入力遅延のステップ数 (0〜255、1 ステップ約 12.5 ps。UG304 4.4.1。範囲は Gowin のモデルの C_STATIC_DLY に合わせた)
//   CAP_EDGE   0 = 立ち上がりで取り込む、1 = 立ち下がりで取り込む
//
// Ports:
//   input  wire        s_clk
//   input  wire [3:0]  cmd           {cs_n, ras_n, cas_n, we_n}
//   input  wire [12:0] addr / [1:0] ba / [1:0] dqm
//   input  wire [15:0] dq_out / dq_oe   書き込む値と、出力するか (1 で出力)
//   output reg  [15:0] dq_in
// SDRAM のピン
// =============================================================

`default_nettype none

module sdram_io #(
    parameter integer IN_DLY   = 160,
    parameter integer CAP_EDGE = 0
) (
    input  wire        s_clk,
    input  wire [3:0]  cmd,
    input  wire [12:0] addr,
    input  wire [1:0]  ba,
    input  wire [1:0]  dqm,
    input  wire [15:0] dq_out,
    input  wire        dq_oe,
    output reg  [15:0] dq_in,

    inout  wire [15:0] sdram_dq,
    output wire [12:0] sdram_addr,
    output wire [1:0]  sdram_ba,
    output wire        sdram_clk,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_dqm
);

    // 出力専用のピン (コマンド 4 本、アドレス 13 本、バンク 2 本、DQM 2 本)
    wire [20:0] o_d = {cmd, addr, ba, dqm};
    wire [20:0] o_q;
    /* verilator lint_off PINCONNECTEMPTY */
    genvar g;
    generate
        for (g = 0; g < 21; g = g + 1) begin : o
            ODDR u_oddr (.D0 (o_d[g]), .D1 (o_d[g]), .TX (1'b0), .CLK (s_clk), .Q0 (o_q[g]), .Q1 ());
        end
    endgenerate
    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_addr, sdram_ba, sdram_dqm} = o_q;

    // SDRAM のクロック (s_clk の反転)
    ODDR u_oddr_clk (.D0 (1'b0), .D1 (1'b1), .TX (1'b0), .CLK (s_clk), .Q0 (sdram_clk), .Q1 ());

    // DQ (出力は ODDR、入力は IODELAY → IDDR。どちらも s_clk)
    wire [15:0] dq_q, dq_oen, dq_pin, dq_dly, dq_rise, dq_fall;
    generate
        for (g = 0; g < 16; g = g + 1) begin : dq
            ODDR    u_oddr  (.D0 (dq_out[g]), .D1 (dq_out[g]), .TX (~dq_oe), .CLK (s_clk), .Q0 (dq_q[g]), .Q1 (dq_oen[g]));
            IOBUF   u_iobuf (.O (dq_pin[g]), .IO (sdram_dq[g]), .I (dq_q[g]), .OEN (dq_oen[g]));
            IODELAY #(.C_STATIC_DLY (IN_DLY), .DYN_DLY_EN ("FALSE"), .ADAPT_EN ("FALSE")) u_dly (
                .DI (dq_pin[g]), .SDTAP (1'b0), .VALUE (1'b0), .DLYSTEP (8'd0), .DO (dq_dly[g]), .DF ()
            );
            IDDR    u_iddr  (.D (dq_dly[g]), .CLK (s_clk), .Q0 (dq_rise[g]), .Q1 (dq_fall[g]));
        end
    endgenerate
    /* verilator lint_on PINCONNECTEMPTY */

    always @(posedge s_clk) dq_in <= (CAP_EDGE != 0) ? dq_fall : dq_rise;

endmodule

`default_nettype wire
