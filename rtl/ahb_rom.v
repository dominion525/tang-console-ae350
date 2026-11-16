// =============================================================
// File:        ae350/rtl/ahb_rom.v
// Module:      ahb_rom
// Role:        ROM_H* (= AE350 が命令を読む AHB) の先に置くブロック RAM の ROM (= 実機の値を読む構成、2026-11-10)。
//              FPGA のロジック側の回路で、中身は合成のときに INIT_FILE (= ae350/tools/bin2hex.rb の hex) から入れる。
//
//   - アドレスフェーズを受けた端でブロック RAM を読み、データフェーズに返す (= 待ちなし)
//   - HADDR の下位 (= WORDS に収まるビット) だけを見る。範囲の外は折り返す
//   - 書き込みは受けるが中身は変えない (= エラー応答は返さない)
//
// Ports:
//   input  wire        hclk / hresetn
//   input  wire [31:0] haddr
//   input  wire [1:0]  htrans
//   input  wire        hwrite
//   output reg  [31:0] hrdata
//   output wire        hready / hresp
//
// Clock:       hclk (= AHB_CLK と同じクロック)
// Reset:       hresetn (= 中身は reset で変わらない。ポートは ROM_H* の形に合わせて持つ)
// =============================================================

`default_nettype none

module ahb_rom #(
    parameter integer WORDS     = 4096,       // 16 KB
    parameter         INIT_FILE = ""
) (
    input  wire        hclk,
    input  wire        hresetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    output reg  [31:0] hrdata,
    output wire        hready,
    output wire        hresp
);

    localparam integer AW = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    assign hready = 1'b1;
    assign hresp  = 1'b0;

    always @(posedge hclk) begin
        if (htrans[1]) hrdata <= mem[haddr[AW+1:2]];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{hresetn, haddr[31:AW+2], haddr[1:0], htrans[0], hwrite};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
