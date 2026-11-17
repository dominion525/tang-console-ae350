// =============================================================
// File:        tb/ahb_ddr_model.v
// Module:      ahb_ddr_model
// Role:        DDR_H* (64 ビット AHB) の先に置くデータメモリのモデル。
//              シミュレーション専用。
//
// Ports:
//   input  wire        clk / rst_n
//   input  wire [31:0] haddr      WORDS を超える上位のビットは見ない
//   input  wire [1:0]  htrans
//   input  wire        hwrite
//   input  wire [2:0]  hsize      0 = 8 ビット、1 = 16 ビット、2 = 32 ビット、3 = 64 ビット
//   input  wire [63:0] hwdata     データフェーズの値。HADDR[2:0] と HSIZE で決まるバイトレーンだけを書き込む
//   output wire [63:0] hrdata     データフェーズの間、受け付けたアドレスの 64 ビットを出力する
//   output wire        hready     受け付けてから +ddr_wait=<N> サイクルの間 0 にする (既定値 0)
//   output wire        hresp      +ddr_err=<16 進のアドレス> の 8 バイトへの転送にはエラー応答 (2 サイクル) を返す。それ以外は 0
//
// Design Notes:
//   - 初期値は全バイト 0xA5 (.bss を 0 にする処理が動いたかを見分けるため)
//   - hready はレジスタだけから作る (htrans に組み合わせ回路で依存しない)
//   - 書き込みはデータフェーズの最後のサイクル (hready = 1) で行う。読み出しは組み合わせ回路
// =============================================================

`default_nettype none

module ahb_ddr_model #(
    parameter integer WORDS = 8192      // 64 ビット × 8192 = 64 KB
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [63:0] hwdata,
    output wire [63:0] hrdata,
    output wire        hready,
    output wire        hresp
);

    localparam integer AW = $clog2(WORDS);

    reg [63:0] mem [0:WORDS-1];

    integer    rand_max;      // 0 より大きければ、ウェイトを転送ごとに 0〜rand_max からランダムに選ぶ (+ddr_wait_rand)
    integer    rand_seed;     // 乱数の種 (+seed。DDR は seed + 1 を使う)
    reg [7:0]  wait_cycles;
    reg [31:0] err_addr;      // この 8 バイトへの転送にはエラー応答を返す (+ddr_err=<16 進>)
    reg        err_en;
    integer    i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = {8{8'hA5}};
        if (!$value$plusargs("ddr_wait=%d", wait_cycles)) wait_cycles = 8'd0;
        if (!$value$plusargs("ddr_wait_rand=%d", rand_max)) rand_max = 0;
        if (!$value$plusargs("seed=%d", rand_seed)) rand_seed = 1;
        rand_seed = rand_seed + 1;
        err_en = 1'b0;
        err_addr = 32'd0;
        if ($value$plusargs("ddr_err=%h", err_addr)) err_en = 1'b1;
    end

    reg [AW-1:0] dph_idx;
    reg [2:0]    dph_lane;    // HADDR[2:0]
    reg [2:0]    dph_size;
    reg          dph_write;
    reg [7:0]    wait_left;
    reg          dph_err;     // このデータフェーズはエラー応答
    reg          err_second;  // エラー応答の 2 サイクル目

    wire accept = htrans[1] && hready;

    // ランダムなウェイト ($random は種を書き換えるので、呼ぶたびに次の値になる)
    function [7:0] next_wait(input [7:0] max);
        reg [31:0] r;
        /* verilator lint_off UNUSEDSIGNAL */
        reg [31:0] q;     // 余りは max 以下なので、上位は常に 0
        /* verilator lint_on UNUSEDSIGNAL */
        begin
            r         = $random(rand_seed);
            q         = r % ({24'd0, max} + 32'd1);
            next_wait = q[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dph_idx   <= {AW{1'b0}};
            dph_lane  <= 3'd0;
            dph_size  <= 3'd0;
            dph_write <= 1'b0;
            wait_left <= 8'd0;
            dph_err   <= 1'b0;
            err_second <= 1'b0;
        end else if (accept) begin
            dph_idx   <= haddr[AW+2:3];
            dph_lane  <= haddr[2:0];
            dph_size  <= hsize;
            dph_write <= hwrite;
            wait_left <= (rand_max > 0) ? next_wait(rand_max[7:0]) : wait_cycles;
            dph_err   <= err_en && (haddr[31:3] == err_addr[31:3]);
            err_second <= 1'b0;
        end else begin
            if (hready) begin
                dph_write <= 1'b0;
                dph_err   <= 1'b0;
            end
            if (wait_left != 8'd0) wait_left <= wait_left - 8'd1;
            err_second <= dph_err && wait_left == 8'd0 && !err_second;
        end
    end

    // 書き込むバイトレーン
    reg [7:0] strobe;
    always @(*) begin
        case (dph_size)
            3'd0:    strobe = 8'b0000_0001 << dph_lane;
            3'd1:    strobe = 8'b0000_0011 << {dph_lane[2:1], 1'b0};
            3'd2:    strobe = 8'b0000_1111 << {dph_lane[2], 2'b00};
            default: strobe = 8'b1111_1111;
        endcase
    end

    integer b;
    always @(posedge clk) begin
        if (dph_write && hready && !dph_err) begin
            for (b = 0; b < 8; b = b + 1) begin
                if (strobe[b]) mem[dph_idx][b*8 +: 8] <= hwdata[b*8 +: 8];
            end
        end
    end

    // エラー応答はウェイトの後の 2 サイクル (1 サイクル目は HREADY = 0、2 サイクル目は HREADY = 1。どちらも HRESP = 1)
    assign hready = (wait_left == 8'd0) && (!dph_err || err_second);
    assign hresp  = (wait_left == 8'd0) && dph_err;
    assign hrdata = mem[dph_idx];

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{haddr[31:AW+3], htrans[0], err_addr[2:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
