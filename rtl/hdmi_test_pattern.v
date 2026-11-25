// =============================================================
// File:        rtl/hdmi_test_pattern.v
// Module:      hdmi_test_pattern
// Role:        HDMI の出力回路 (rtl/vendor/hdmi/hdmi.sv) に渡すテストパターン。横の座標から色を決める
//              カラーバー (幅 160 ドットの 8 本。左から白、黄、シアン、緑、マゼンタ、赤、青、黒)。
//
//   - hdmi.sv は、cx が指す画素の色を次のクロックで受け取るので、色はレジスタに入れて 1 クロック遅らせて出す
//   - 表示期間の外 (cx が 1280 以上) は黒を出す (hdmi.sv は表示期間の外の色を使わない)
//
// Ports:
//   input  wire        clk   画素クロック
//   input  wire [10:0] cx    hdmi.sv の横の座標 (0〜1649)
//   output reg  [23:0] rgb   {赤, 緑, 青} 各 8 ビット
//
// Clock:       clk
// Reset:       なし (rgb は毎クロック cx から決め直す)
// =============================================================

`default_nettype none

module hdmi_test_pattern (
    input  wire        clk,
    input  wire [10:0] cx,
    output reg  [23:0] rgb
);
    always @(posedge clk) begin
        if      (cx < 11'd160)  rgb <= 24'hFFFFFF;   // 白
        else if (cx < 11'd320)  rgb <= 24'hFFFF00;   // 黄
        else if (cx < 11'd480)  rgb <= 24'h00FFFF;   // シアン
        else if (cx < 11'd640)  rgb <= 24'h00FF00;   // 緑
        else if (cx < 11'd800)  rgb <= 24'hFF00FF;   // マゼンタ
        else if (cx < 11'd960)  rgb <= 24'hFF0000;   // 赤
        else if (cx < 11'd1120) rgb <= 24'h0000FF;   // 青
        else                    rgb <= 24'h000000;   // 黒 (表示期間の外も)
    end
endmodule

`default_nettype wire
