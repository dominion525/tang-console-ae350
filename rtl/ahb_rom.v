// =============================================================
// File:        rtl/ahb_rom.v
// Module:      ahb_rom
// Role:        ROM_H* (AE350 が命令をフェッチする AHB) の先に置く、ブロック RAM で作った ROM。
//              ファブリック側の回路で、内容は合成時に INIT_FILE (tools/bin2hex.rb が出力する hex) から読み込む。
//
//   - アドレスフェーズを受け付けたクロックエッジでブロック RAM を読み、データフェーズで返す (ウェイトなし)
//   - HADDR は下位 (WORDS に収まるビット) だけを見る。範囲外のアドレスは折り返す
//   - 書き込みは受け付けるが、内容は変えない (エラー応答は返さない)
//
// Ports:
//   input  wire        hclk / hresetn
//   input  wire [31:0] haddr
//   input  wire [1:0]  htrans
//   input  wire        hwrite
//   output reg  [31:0] hrdata
//   output wire        hready / hresp
//
// Clock:       hclk (AHB_CLK と同じクロック)
// Reset:       hresetn (内容はリセットで変わらない。ポートは ROM_H* に合わせて持つ)
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
