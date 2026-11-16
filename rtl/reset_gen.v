// =============================================================
// File:        rtl/reset_gen.v
// Module:      reset_gen
// Role:        ボタンから FPGA のロジック側の rst_n を作る (= 2026-10-23)。
//              ボタンの整形 (= A) と reset synchronizer (= B) をつなぐ。
//
//              A  ボタンを FF 2 段でクロックに合わせて取り込み、押された状態が PRESS_CYCLES 続いたら
//                 reset を要求し、離された状態が RELEASE_CYCLES 続いたら要求を下ろす。途中で戻ったら数え直す
//                 (= チャタリング除去)。FF の初期値は「押されている」側にし、書き込み直後も
//                 RELEASE_CYCLES の間 reset を保つ (= 電源投入時の reset)
//              B  A の要求で、クロックを待たずに reset に入り、解けるのはクロックの立ち上がり 2 回の後
//                 (= Cummings, Mills, Golson "Asynchronous & Synchronous Reset Design Techniques - Part Deux",
//                 SNUG Boston 2003 の 7 節、Example 8a の形)
//
// Parameters:
//   PRESS_CYCLES   = 25000    押された状態が続く cycle 数 (= 25 MHz で 1 ms)。雑音で reset に入らないように待つ
//   RELEASE_CYCLES = 500000   離された状態が続く cycle 数 (= 25 MHz で 20 ms)。ばたつきの実測の最大 6.2 ms
//                             (= Ganssle "A Guide to Debouncing" 第 1 部) の 3 倍ほど
//
// Ports:
//   input  wire clk
//   input  wire btn_n    ボタン。押すと 0。クロックと関係なく変わり、ばたつく
//   input  wire lock     PLL の LOCK (= 周波数が安定したら 1)。0 の間は、クロックを待たずに reset に入る
//                        (= 2026-10-24)。PLL を使わないときは 1 に結ぶ
//   output wire rst_n    FPGA のロジック側に渡す reset (= active low)。0 になるのはクロックを待たず、
//                        1 になるのはクロックの立ち上がりの直後
//
// Reset:       無し。FF はすべて初期値で始まる (= Gowin SUG949 3.2 節「FF には初期値を付ける」)
// Clock:       posedge clk
//
// Testbench:
//   tb/reset_gen_tb.cpp
//   make reset_gen
//
// Design Notes:
//   - **B は A の要求と PLL の LOCK を合わせて受ける。**PLL が外れるとクロックが止まりうるので、
//     LOCK が 0 になったらクロックを待たずに reset に入る。LOCK が 1 に戻ったら、クロックの立ち上がり 2 回の後に解ける
//   - **LOCK が外れても A は数え直さない。**A の要求がもう下りていれば、LOCK が戻って 2 cycle で解ける。
//     電源投入では A が「押されている」から始まるので、LOCK が立った後に RELEASE_CYCLES を数えてから解ける
//   - B の 2 段目は準安定にならない。reset が解けるとき、入力 (= 1 段目) と出力がどちらも 0 で差が無いため
//     (= 同論文 7.1 節)。1 段目は準安定になりうるので、2 段目で 1 cycle 落ち着かせる
//   - B の FF は reset の値と初期値をどちらも 0 にそろえる (= SUG949 3.2 節「初期値と reset の値をそろえる」)
//   - 書き込み直後から rst_n が 1 になるまで RELEASE_CYCLES + 4 cycle かかる (= A の取り込み 2、数える分、要求の切り替え、B の 2)
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

    // この回路の FF は reset を持たず、宣言の初期値で始まる (= SUG949 3.2 節の形)。always での代入と併せると
    // PROCASSINIT が出るので、このファイルの中だけで抑止する。
    // req_n は A の同期の値で、B の非同期の reset でもある (= Cummings の形。B が解くのはクロックに合わせてなので
    // 準安定は 2 段目で止まる)。SYNCASYNCNET もこのファイルの中だけで抑止する。
    /* verilator lint_off PROCASSINIT */
    /* verilator lint_off SYNCASYNCNET */

    // ---------------------------------------------------------
    // A: ボタンの整形
    // ---------------------------------------------------------

    // 取り込み。初期値は「押されている」(= 0)。
    reg btn_meta = 1'b0;
    reg btn_sync = 1'b0;

    always @(posedge clk) begin
        btn_meta <= btn_n;
        btn_sync <= btn_meta;
    end

    // req_n は reset の要求 (= 0 で要求している)。初期値は要求している側。
    // btn_sync が req_n と違う状態のまま決まった cycle 数続いたら、req_n をそちらに切り替える。
    localparam MAX_CYCLES = (PRESS_CYCLES > RELEASE_CYCLES) ? PRESS_CYCLES : RELEASE_CYCLES;
    localparam CW = (MAX_CYCLES > 1) ? $clog2(MAX_CYCLES) : 1;
    // 32 bit で引いてからカウンタの幅に切る (= 幅の違う値を直に入れない)。
    localparam [31:0]   PRESS_LAST32   = PRESS_CYCLES - 1;
    localparam [31:0]   RELEASE_LAST32 = RELEASE_CYCLES - 1;
    localparam [CW-1:0] PRESS_LAST     = PRESS_LAST32[CW-1:0];
    localparam [CW-1:0] RELEASE_LAST   = RELEASE_LAST32[CW-1:0];

    reg          req_n = 1'b0;
    reg [CW-1:0] cnt   = {CW{1'b0}};

    // いま要求していないなら押されるのを、要求しているなら離されるのを待つ。
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

    // A の要求と PLL の LOCK を合わせて、B を非同期にクリアする。
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
