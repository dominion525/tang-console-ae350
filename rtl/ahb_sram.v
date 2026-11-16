// =============================================================
// File:        ae350/rtl/ahb_sram.v
// Module:      ahb_sram
// Role:        AE350 の EXTS_H* の先に置く、32 bit の AHB のスレーブの RAM (= 段 5、2026-11-10)。
//              FPGA のロジック側の回路で、実機にもそのまま載る (= ブロック RAM と同じく、読み出しを 1 段の
//              レジスタで受ける形)。
//
// Address:     HADDR[AW+1:2] で RAM の word を選ぶ。HADDR[26:AW+2] が 0 でない (= RAM の外) 転送には、
//              2 サイクルのエラー応答を返す。HADDR[31:27] は見ない (= EXTS_H* の範囲は 0xE800_0000〜0xEFFF_FFFF)
//
// Ports (= AHB のスレーブ):
//   input  wire        hclk / hresetn
//   input  wire        hsel / hready      hready はバスの HREADY (= このスレーブだけなら hreadyout と同じ)
//   input  wire [31:0] haddr
//   input  wire [1:0]  htrans
//   input  wire        hwrite
//   input  wire [2:0]  hsize               0 = 8 bit、1 = 16 bit、2 = 32 bit
//   input  wire [31:0] hwdata              データフェーズの値。HADDR[1:0] と HSIZE で決まるバイトレーンだけを書く
//   output wire [31:0] hrdata
//   output wire        hreadyout
//   output wire        hresp
//
// Parameters:
//   WORDS   RAM の word 数 (= 2 のべき乗。既定 1024 = 4 KB)
//   WAIT    データフェーズに入れる待ちのサイクル数 (= 0 なら待たない)
// =============================================================

`default_nettype none

module ahb_sram #(
    parameter integer WORDS = 1024,
    parameter integer WAIT  = 0
) (
    input  wire        hclk,
    input  wire        hresetn,
    input  wire        hsel,
    input  wire        hready,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    output wire [31:0] hrdata,
    output wire        hreadyout,
    output wire        hresp
);

    localparam integer AW = $clog2(WORDS);

    wire accept = hsel && htrans[1] && hready;
    wire in_ram = (haddr[26:AW+2] == {(25-AW){1'b0}});

    // データフェーズ
    reg [AW-1:0] dph_idx;
    reg [3:0]    dph_strb;
    reg          dph_write;
    reg          dph_err;
    reg          err_second;
    reg [7:0]    wait_left;

    // 書くバイトレーン
    reg [3:0] aph_strb;
    always @(*) begin
        case (hsize)
            3'd0:    aph_strb = 4'b0001 << haddr[1:0];
            3'd1:    aph_strb = 4'b0011 << {haddr[1], 1'b0};
            default: aph_strb = 4'b1111;
        endcase
    end

    localparam [31:0] WAIT32 = WAIT;
    localparam [7:0]  WAIT8  = WAIT32[7:0];

    // 前の転送の書き込み (= このサイクルで RAM に入る)
    wire wr_now = dph_write && hreadyout;

    // 書いた直後に同じ word を読むときは、書いたバイトを RAM の値の代わりに返す (= 受けたときに控える)
    reg       rd_zero;     // RAM の外を読んだ (= 0 を返す)
    reg [3:0] fwd_strb;    // 書いた値を返すバイトレーン
    reg [31:0] fwd_data;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            dph_idx    <= {AW{1'b0}};
            dph_strb   <= 4'd0;
            dph_write  <= 1'b0;
            dph_err    <= 1'b0;
            err_second <= 1'b0;
            wait_left  <= 8'd0;
            rd_zero    <= 1'b0;
            fwd_strb   <= 4'd0;
            fwd_data   <= 32'd0;
        end else if (accept) begin
            dph_idx    <= haddr[AW+1:2];
            dph_strb   <= aph_strb;
            dph_write  <= hwrite && in_ram;
            dph_err    <= !in_ram;
            err_second <= 1'b0;
            wait_left  <= WAIT8;
            rd_zero    <= !in_ram;
            fwd_strb   <= (wr_now && haddr[AW+1:2] == dph_idx) ? dph_strb : 4'd0;
            fwd_data   <= hwdata;
        end else begin
            if (hreadyout) begin
                dph_write <= 1'b0;
                dph_err   <= 1'b0;
            end
            if (wait_left != 8'd0) wait_left <= wait_left - 8'd1;
            err_second <= dph_err && wait_left == 8'd0 && !err_second;
        end
    end

    // RAM は 1 byte 幅を 4 本に分ける (= ブロック RAM にする)。書き込みは書くバイトの RAM にだけ、データフェーズの
    // 最後のサイクル (= hreadyout = 1) で行う。読み出しは受けた端で 1 か所を読み、レジスタで受ける
    // (= クロックを待たない読み出しと、リセット付きの読み出しのレジスタは、ブロック RAM にならない)
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : lane
            reg [7:0] mem [0:WORDS-1];
            reg [7:0] q;

            always @(posedge hclk) begin
                if (wr_now && dph_strb[g]) mem[dph_idx] <= hwdata[g*8 +: 8];
            end

            always @(posedge hclk) begin
                if (accept) q <= mem[haddr[AW+1:2]];
            end

            assign hrdata[g*8 +: 8] = rd_zero     ? 8'd0 :
                                      fwd_strb[g] ? fwd_data[g*8 +: 8] :
                                                    q;
        end
    endgenerate

    // エラー応答は待ちの後の 2 サイクル (= 1 サイクル目は HREADYOUT = 0、2 サイクル目は 1。どちらも HRESP = 1)
    assign hreadyout = (wait_left == 8'd0) && (!dph_err || err_second);
    assign hresp     = (wait_left == 8'd0) && dph_err;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{haddr[31:27], haddr[1:0], htrans[0], WAIT32[31:8]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
