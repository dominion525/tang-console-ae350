// =============================================================
// File:        rtl/sdram_io.v
// Module:      sdram_io
// Role:        SDR SDRAM (= W9825G6KH) のピンまわり (= 2026-11-11、166.7 MHz 版の制御のための部品)。
//              すべてのピンを IO の中のレジスタ (= Gowin の ODDR / IDDR) から出し入れし、ピンでの時刻をそろえる。
//              1 本のピンの ODDR と IDDR は同じクロックでなければならないので (= 合成の CK0012)、どちらも s_clk で動かし、
//              読んだデータを取る位置は、IO の中の遅れの部品 (= IODELAY) と、取る縁 (= 立ち上がりか立ち下がり) で決める。
//
//   命令、番地、DQM     ODDR (= D0 = D1) で s_clk の立ち上がりから出す
//   DQ の出力と許可      ODDR の Q0 (= 値) と Q1 (= IOBUF の OEN、1 で出さない) で、同じ遅れで出す
//   DQ の入力           ピン → IODELAY (= IN_DLY × 約 12.5 ps) → IDDR。CAP_EDGE が 0 なら立ち上がりで取った Q0、1 なら
//                      立ち下がりで取った Q1 を、s_clk でもう 1 段受けて dq_in に出す
//   SDRAM のクロック     ODDR (= D0 = 0、D1 = 1) で s_clk を反転して出す。命令が変わる縁の半周期後に、SDRAM が受ける
//
//   遅れ (= Gowin の部品のモデルのとおり。tb/gowin_io_models.v):
//     出力: s_clk の縁 n で入れた値が、縁 n + 2 からピンに出る (= 命令も DQ もそろって 2 サイクル)
//     入力: 立ち上がり m で取った値は縁 m + 3 の後に、立ち下がり m - 0.5 で取った値は縁 m + 2 の後に dq_in に出る
//           (= IDDR の中で、立ち下がりの側は 1 段短い)
//
// Parameters:
//   IN_DLY     DQ の入力の遅れの刻み (= 0〜255、1 刻み約 12.5 ps。UG304 4.4.1。範囲は Gowin のモデルの C_STATIC_DLY に合わせた)
//   CAP_EDGE   0 = 立ち上がりで取る、1 = 立ち下がりで取る
//
// Ports:
//   input  wire        s_clk
//   input  wire [3:0]  cmd           {cs_n, ras_n, cas_n, we_n}
//   input  wire [12:0] addr / [1:0] ba / [1:0] dqm
//   input  wire [15:0] dq_out / dq_oe   書く値と、出す (= 1) か
//   output reg  [15:0] dq_in
//   SDRAM のピン
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

    // 出力だけのピン (= 命令 4 本、番地 13 本、バンク 2 本、DQM 2 本)
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

    // SDRAM のクロック (= s_clk の反転)
    ODDR u_oddr_clk (.D0 (1'b0), .D1 (1'b1), .TX (1'b0), .CLK (s_clk), .Q0 (sdram_clk), .Q1 ());

    // DQ (= 出力は ODDR、入力は IODELAY → IDDR。どちらも s_clk)
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
