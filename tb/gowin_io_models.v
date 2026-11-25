// =============================================================
// File:        tb/gowin_io_models.v
// Role:        シミュレーション用の、Gowin の IO プリミティブ (ODDR、IDDR、IOBUF、IODELAY、ELVDS_OBUF) のモデル。
//              Gowin のモデル (simlib/gw5a/prim_sim.v) は手続き内の assign と deassign を使っていて Verilator で動かないので、
//              同じ遅延の動作だけを写した。GSR (グローバルリセット) と INIT 以外のパラメータは持たない。
//              実機では使わない (合成では Gowin の本物のプリミティブになる)。
//
//   ODDR   D0、D1、TX を CLK の立ち上がりで取り込み、2 サイクル後の立ち上がりから出力する。Q0 は CLK が 1 の半周期に D0、
//          0 の半周期に D1。Q1 は TX (TXCLK_POL が 0 のとき、立ち上がりで変わる)
//   IDDR   D を立ち上がりで取り込んで 2 サイクル後に Q0 に、立ち下がりで取り込んで Q1 に出力する
//   IOBUF  OEN が 0 のとき I をピンに出力する。O はピンの値
//   IODELAY  DI を C_STATIC_DLY × 12.5 ps 遅らせて DO に出力する (静的な設定だけ。UG304 4.4.1 の「1 ステップ約 12.5 ps」)
//   ELVDS_OBUF  I を O に、反転した値を OB に出力する (HDMI の出力。make lint のボード構成で使う)
// =============================================================

`default_nettype none

module ODDR #(
    parameter TXCLK_POL = 1'b0,
    parameter INIT      = 1'b0
) (
    input  wire D0,
    input  wire D1,
    input  wire TX,
    input  wire CLK,
    output wire Q0,
    output wire Q1
);
    reg d0_0 = INIT, d0_1 = INIT, d0_2 = INIT;
    reg d1_0 = INIT, d1_1 = INIT, d1_2 = INIT;
    reg tx_0 = INIT, tx_1 = INIT, tx_p = INIT, tx_n = INIT;

    always @(posedge CLK) begin
        d0_0 <= D0;
        d1_0 <= D1;
        d0_1 <= d0_0;
        d1_1 <= d1_0;
        tx_0 <= TX;
        tx_1 <= tx_0;
        d1_2 <= d1_1;
        tx_p <= tx_n;
    end

    always @(negedge CLK) begin
        d0_2 <= d0_1;
        tx_n <= tx_1;
    end

    assign Q0 = CLK ? d0_2 : d1_2;
    assign Q1 = (TXCLK_POL == 1'b0) ? tx_p : tx_n;
endmodule

module IDDR #(
    parameter Q0_INIT = 1'b0,
    parameter Q1_INIT = 1'b0
) (
    input  wire D,
    input  wire CLK,
    output wire Q0,
    output wire Q1
);
    reg q0_i = Q0_INIT, q0_o = Q0_INIT, q0_r = Q0_INIT;
    reg q1_i = Q1_INIT, q1_o = Q1_INIT, q1_r = Q1_INIT;

    always @(posedge CLK) begin
        q0_i <= D;
        q0_o <= q0_i;
        q0_r <= q0_o;
        q1_o <= q1_i;
        q1_r <= q1_o;
    end

    always @(negedge CLK) q1_i <= D;

    assign Q0 = q0_r;
    assign Q1 = q1_r;
endmodule

module ELVDS_OBUF (
    output wire O,
    output wire OB,
    input  wire I
);
    assign O  = I;
    assign OB = ~I;
endmodule

module IOBUF (
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire OEN
);
    assign IO = OEN ? 1'bz : I;
    assign O  = IO;
endmodule

module IODELAY #(
    parameter integer C_STATIC_DLY = 0,
    parameter         DYN_DLY_EN   = "FALSE",
    parameter         ADAPT_EN     = "FALSE"
) (
    input  wire       DI,
    input  wire       SDTAP,
    input  wire       VALUE,
    input  wire [7:0] DLYSTEP,
    output wire       DO,
    output wire       DF
);
    localparam real D_NS = C_STATIC_DLY * 0.0125;
    generate
        if (C_STATIC_DLY == 0) begin : no_delay
            assign DO = DI;
        end else begin : delay
            assign #(D_NS) DO = DI;
        end
    endgenerate
    assign DF = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{SDTAP, VALUE, DLYSTEP};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
