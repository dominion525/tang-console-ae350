// =============================================================
// File:        rtl/reset_gen.v
// Module:      reset_gen
// Role:        ボタン入力から、ファブリック側の回路に渡す rst_n を生成する。
//              ボタン入力の整形 (A) と、リセット同期化回路 (B) をつなぐ。
//
//              A  ボタン入力を 2 段の FF でクロックに同期させて取り込む。押された状態が PRESS_CYCLES 続いたら
//                 リセットを要求し、離された状態が RELEASE_CYCLES 続いたら要求を取り下げる。途中で状態が戻ったら
//                 数え直す (チャタリング除去)。FF の初期値は「押されている」側にし、コンフィグレーション直後も
//                 RELEASE_CYCLES の間リセットを保つ (パワーオンリセット)
//              B  A の要求で、クロックを待たずにリセットに入り、クロックの立ち上がり 2 回の後に解除する
//                 (Cummings, Mills, Golson "Asynchronous & Synchronous Reset Design Techniques - Part Deux",
//                 SNUG Boston 2003 の 7 節、Example 8a の構成)
//
// Parameters:
//   PRESS_CYCLES   = 25000    押された状態が続くサイクル数 (25 MHz で 1 ms)。ノイズでリセットに入らないように待つ
//   RELEASE_CYCLES = 500000   離された状態が続くサイクル数 (25 MHz で 20 ms)。チャタリングの実測の最大値 6.2 ms
//                             (Ganssle "A Guide to Debouncing" 第 1 部) の約 3 倍
//
// Ports:
//   input  wire clk
//   input  wire btn_n    ボタン入力。押すと 0。クロックと非同期に変化し、チャタリングがある
//   input  wire lock     PLL の LOCK (周波数が安定すると 1)。0 の間は、クロックを待たずにリセットに入る。
//                        PLL を使わないときは 1 に固定する
//   output wire rst_n    ファブリック側の回路に渡すリセット (アクティブ Low)。アサートはクロックを待たず、
//                        解除はクロックの立ち上がりの直後
//
// Reset:       なし。FF はすべて初期値から始まる (Gowin SUG949 3.2 節「FF には初期値を付ける」)
// Clock:       posedge clk
//
// Design Notes:
//   - **B は A の要求と PLL の LOCK をまとめて受ける。**PLL のロックが外れるとクロックが止まることがあるので、
//     LOCK が 0 になったらクロックを待たずにリセットに入る。LOCK が 1 に戻ったら、クロックの立ち上がり 2 回の後に解除する
//   - **LOCK が外れても A は数え直さない。**A の要求がすでに取り下げられていれば、LOCK が戻ってから 2 サイクルで解除する。
//     電源投入時は A が「押されている」状態から始まるので、LOCK が立った後に RELEASE_CYCLES を数えてから解除する
//   - B の 2 段目の FF はメタステーブルにならない。リセットが解除されるとき、入力 (1 段目) と出力がどちらも 0 で
//     差がないため (同論文 7.1 節)。1 段目はメタステーブルになりうるので、2 段目で 1 サイクル待って安定させる
//   - B の FF は、リセット値と初期値をどちらも 0 に揃える (SUG949 3.2 節「初期値とリセット値を揃える」)
//   - コンフィグレーション直後から rst_n が 1 になるまで、RELEASE_CYCLES + 4 サイクルかかる (A の取り込み 2、カウント、
//     要求の切り替え、B の 2)
// =============================================================

`default_nettype none

module reset_gen #(
    parameter PRESS_CYCLES   = 25000,
    parameter RELEASE_CYCLES = 500000
) (
    input  wire clk,
    input  wire btn_n,
    input  wire lock,
    output wire rst_n
);

    // この回路の FF はリセットを持たず、宣言の初期値から始まる (SUG949 3.2 節の形)。always での代入と併せると
    // PROCASSINIT 警告が出るので、このファイルの中だけで抑止する。
    // req_n は A の同期化された値で、B の非同期リセットでもある (Cummings の構成。B はクロックに同期して解除するので、
    // メタステーブルは 2 段目で止まる)。SYNCASYNCNET 警告も、このファイルの中だけで抑止する。
    /* verilator lint_off PROCASSINIT */
    /* verilator lint_off SYNCASYNCNET */

    // ---------------------------------------------------------
    // A: ボタン入力の整形
    // ---------------------------------------------------------

    // 取り込み。初期値は「押されている」(0)。
    reg btn_meta = 1'b0;
    reg btn_sync = 1'b0;

    always @(posedge clk) begin
        btn_meta <= btn_n;
        btn_sync <= btn_meta;
    end

    // req_n はリセットの要求 (0 で要求中)。初期値は要求している側。
    // btn_sync が req_n と異なる状態のまま決まったサイクル数続いたら、req_n をそちらに切り替える。
    localparam MAX_CYCLES = (PRESS_CYCLES > RELEASE_CYCLES) ? PRESS_CYCLES : RELEASE_CYCLES;
    localparam CW = (MAX_CYCLES > 1) ? $clog2(MAX_CYCLES) : 1;
    // 32 ビットで引き算してから、カウンタの幅に切り詰める (幅の異なる値を直接代入しない)。
    localparam [31:0]   PRESS_LAST32   = PRESS_CYCLES - 1;
    localparam [31:0]   RELEASE_LAST32 = RELEASE_CYCLES - 1;
    localparam [CW-1:0] PRESS_LAST     = PRESS_LAST32[CW-1:0];
    localparam [CW-1:0] RELEASE_LAST   = RELEASE_LAST32[CW-1:0];

    reg          req_n = 1'b0;
    reg [CW-1:0] cnt   = {CW{1'b0}};

    // 要求していなければ押されるのを、要求していれば離されるのを待つ。
    wire [CW-1:0] last = req_n ? PRESS_LAST : RELEASE_LAST;

    always @(posedge clk) begin
        if (btn_sync == req_n) begin
            cnt <= {CW{1'b0}};
        end else if (cnt == last) begin
            req_n <= btn_sync;
            cnt   <= {CW{1'b0}};
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    // ---------------------------------------------------------
    // B: reset synchronizer
    // ---------------------------------------------------------

    // A の要求と PLL の LOCK をまとめて、B を非同期にクリアする。
    wire b_clr_n = req_n & lock;

    reg rff1    = 1'b0;
    reg rst_n_q = 1'b0;

    always @(posedge clk or negedge b_clr_n) begin
        if (!b_clr_n) begin
            {rst_n_q, rff1} <= 2'b00;
        end else begin
            {rst_n_q, rff1} <= {rff1, 1'b1};
        end
    end

    assign rst_n = rst_n_q;

    /* verilator lint_on SYNCASYNCNET */
    /* verilator lint_on PROCASSINIT */

endmodule

`default_nettype wire
