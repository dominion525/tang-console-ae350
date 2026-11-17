// =============================================================
// File:        tb/ahb_rom_model.v
// Module:      ahb_rom_model
// Role:        ROM_H* (32 ビット、読み出し専用の AHB) の先に置く命令メモリのモデル。
//              シミュレーション専用。内容は +rom=<hex> で指定した hex ファイル (1 行 1 ワード) から読み込む。
//
// Ports:
//   input  wire        clk / rst_n
//   input  wire [31:0] haddr      下位 2 ビットと、WORDS を超える上位のビットは見ない
//   input  wire [1:0]  htrans
//   output wire [31:0] hrdata     データフェーズの間、受け付けたアドレスのワードを出力する
//   output wire        hready     受け付けてから +rom_wait=<N> サイクルの間 0 にする (既定値 0)
//   output wire        hresp      +rom_err=<16 進のアドレス> の 4 バイトの読み出しにはエラー応答 (2 サイクル) を返す。それ以外は 0
//
// Design Notes:
//   - hready はレジスタだけから作る (htrans に組み合わせ回路で依存しない)
//   - 読み出しは組み合わせ回路 (データフェーズの間、保持したアドレスで配列を引く)
// =============================================================

`default_nettype none

module ahb_rom_model #(
    parameter integer WORDS = 16384     // 64 KB
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp
);

    localparam integer AW = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];

    reg [8*256-1:0] path;
    integer    rand_max;      // 0 より大きければ、ウェイトを転送ごとに 0〜rand_max からランダムに選ぶ (+rom_wait_rand)
    integer    rand_seed;     // 乱数の種 (+seed。ROM は seed をそのまま使う)
    reg [7:0]       wait_cycles;
    reg [31:0]      err_addr;      // この 4 バイトの読み出しにはエラー応答を返す (+rom_err=<16 進>)
    reg             err_en;
    integer         i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0000_0000;
        if ($value$plusargs("rom=%s", path)) begin
            $readmemh(path, mem);
        end else begin
            $display("ahb_rom_model: +rom=<hex> is missing");
            $finish;
        end
        if (!$value$plusargs("rom_wait=%d", wait_cycles)) wait_cycles = 8'd0;
        if (!$value$plusargs("rom_wait_rand=%d", rand_max)) rand_max = 0;
        if (!$value$plusargs("seed=%d", rand_seed)) rand_seed = 1;
        err_en   = 1'b0;
        err_addr = 32'd0;
        if ($value$plusargs("rom_err=%h", err_addr)) err_en = 1'b1;
    end

    reg [AW-1:0] dph_idx;
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
            dph_idx    <= {AW{1'b0}};
            wait_left  <= 8'd0;
            dph_err    <= 1'b0;
            err_second <= 1'b0;
        end else if (accept) begin
            dph_idx    <= haddr[AW+1:2];
            wait_left  <= (rand_max > 0) ? next_wait(rand_max[7:0]) : wait_cycles;
            dph_err    <= err_en && (haddr[31:2] == err_addr[31:2]);
            err_second <= 1'b0;
        end else begin
            if (hready) dph_err <= 1'b0;
            if (wait_left != 8'd0) wait_left <= wait_left - 8'd1;
            err_second <= dph_err && wait_left == 8'd0 && !err_second;
        end
    end

    // エラー応答はウェイトの後の 2 サイクル (1 サイクル目は HREADY = 0、2 サイクル目は HREADY = 1。どちらも HRESP = 1)
    assign hready = (wait_left == 8'd0) && (!dph_err || err_second);
    assign hresp  = (wait_left == 8'd0) && dph_err;
    assign hrdata = mem[dph_idx];

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{haddr[1:0], htrans[0], err_addr[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
