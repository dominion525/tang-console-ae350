// =============================================================
// File:        rtl/ae350_plic.v
// Module:      ae350_plic
// Role:        AE350 のモックの中の PLIC (= Andes NCEPLIC100 と同じ挙動、段 4、2026-11-10)。
//              シミュレーション専用。ターゲットは 0 (= hart 0 の M モード、meip) と 1 (= S モード、seip) [実機]。
//
// 出典 (2026-11-10 に確かめた):
//   [AX45] AndesCore AX45MP-1C Processor Reference Manual (UM248) 18 章 NCEPLIC100
//          (= Gowin の IPUG528 (AE250) 21 章も同じ文面)
//   [BSP]  Gowin の AE350 の BSP (plic.h、ae350.h、ae350.c)
//   [1031] Gowin MUG1031 3.1 (= 「Number of interrupt priorities: 15」。実機は 3 だった)
//   [実機] Tang Console 138K (= チップの版 B) で読んだ値と挙動 (= 2026-11-10。sw/probe.c)
//
// Registers (= モックが 0xE400_0000 からのオフセットで渡す。32 bit のアクセスだけを受ける):
//   0x00_0000          feature        R/W   bit0 PREEMPT、bit1 VECTORED。初期値 0 [AX45 18.4.1]
//                                           VECTORED は読み書きできるだけ (= CPU との専用の信号は Hazard3 に無い)
//   0x00_0000 + 4*id   priority[id]   R/W   id = 1〜NUM_SRC。初期値 1 [AX45 18.4.3]。下位 PRIO_BITS bit を持つ
//   0x00_1000          pending        R/W   読むと IP。書くと「IP |= 書いた値」(= 0 を書いても落ちない。落とせるのは
//                                           claim だけ) [AX45 18.4.4]
//   0x00_1080          trigger        R     パラメータ EDGE_TRIGGER (= 0 レベル、1 エッジ) [AX45 18.4.5]
//   0x00_1100          number         R     {NUM_TARGET, NUM_SRC} [AX45 18.4.6]
//   0x00_1104          version        R     {MAX_PRIORITY, VERSION} [AX45 18.4.7]
//   ターゲット t (= 0 / 1) ごとに持つもの (= t が 1 なら、enable は +0x80、ほかは +0x1000) [実機]:
//   0x00_2000          enable         R/W   bit id = ソース id を通知する
//   0x20_0000          threshold      R/W   priority がこれより大きいソースだけを通知する [AX45 18.4.9]
//   0x20_0004          claim/complete R/W   読むと claim、ID を書くと complete [AX45 18.4.10]
//   0x20_0400〜041C    PPS            R/W   横取りされた優先度のスタック。bit p = 優先度 p が横取りされている。
//                                           初期値 0 [AX45 18.4.11]。持つのは 2^PRIO_BITS bit (= ワード 0 の下位)
//   それ以外                                 読むと 0、書いても何も起きない
//
// 挙動:
//   - ゲートウェイ: 要求を 1 つ報告すると (= IP を立てると)、complete まで次の要求を受けない [AX45 18.1]。
//     レベル: 止まっていなくて入力が 1 なら IP を立てる。complete の時点で 1 のままなら、また立つ。
//     エッジ: 止まっていなくて立ち上がりが来たら IP を立てる。止まっている間のエッジは捨てる (= 数えない)
//   - 通知 (meip): IP かつ enable かつ priority > threshold のソースがある [AX45 18.4.9]
//   - claim: IP かつ enable かつ priority > 0 (CLAIM_ABOVE_THRESHOLD = 1 なら、さらに priority > threshold) のうち、
//     priority が最大のもの (= 同じなら id の小さい方) を返し、その IP を落とす。無ければ 0。
//     PREEMPT = 1 で ID ≠ 0 なら、PPS の bit threshold を立て、threshold に priority[ID] を書く [AX45 18.2.1]
//   - complete: ゲートウェイを再開する。そのソースの enable が立っていなくても効く [実機] (= [AX45 18.4.10] は
//     「enable が立っていなければ無視する」と読めるが、実機は効いた)。PREEMPT = 1 で PPS が空でなければ、PPS で最も高い優先度 p を threshold に
//     書き戻し、bit p を落とす [AX45 18.2.2]
//
// 実機で確かめた値 (= 既定値にした) [実機]:
//   0x1100 = 0x0002_001F (= ターゲット 2、ソース 31)、0x1104 = 0x0003_0001 (= 最大優先度 3、版 1)、0x1080 = 0、
//   priority と threshold は下位 2 bit だけを持つ、claim はしきい値で絞る (= CLAIM_ABOVE_THRESHOLD = 1)、
//   PREEMPT の claim / complete と PPS はこの作りどおり、PPS が空のときの complete は threshold を変えない。
//   GP_INT[0] はソース 4、GP_INT[1〜15] はソース 11〜25 (= rtl/AE350_SOC.v の plic_src)
//
// Ports:
//   input  wire          clk / rst_n
//   input  wire [31:1]   src       割り込みのソース (= clk に同期済み)
//   input  wire          wen / ren このサイクルに書く / 読む (= claim の副作用を起こす)
//   input  wire [21:0]   addr      バイトのオフセット (= 下位 2 bit は見ない)
//   input  wire [31:0]   wdata
//   input  wire [3:0]    wstrb     書き込みは 4 byte 全部 (= wstrb が 4'hF) のときだけ受ける
//   output reg  [31:0]   rdata     addr のレジスタの値 (= 組み合わせ回路)
//   output wire          meip      ターゲット 0 への通知 (= 実機では mip の bit 11)
//   output wire          seip      ターゲット 1 への通知 (= 実機では mip の bit 9。Hazard3 には S モードが無いので、モックでは使わない)
// =============================================================

`default_nettype none

module ae350_plic #(
    parameter integer NUM_SRC               = 31,            // [実機] 0x1100 の下位
    parameter integer NUM_TARGET            = 2,             // [実機] 0x1100 の上位 (= 0 は M モード、1 は S モード)
    parameter integer PRIO_BITS             = 2,             // [実機] 3 段 (= 0x1104 の MAX_PRIORITY 3)
    parameter [15:0]  VERSION               = 16'h0001,      // [実機] 0x1104 の下位
    parameter [31:0]  EDGE_TRIGGER          = 32'h0000_0000, // 全ソースがレベル
    parameter integer CLAIM_ABOVE_THRESHOLD = 1
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [31:1]   src,
    input  wire          wen,
    input  wire          ren,
    input  wire [21:0]   addr,
    input  wire [31:0]   wdata,
    input  wire [3:0]    wstrb,
    output reg  [31:0]   rdata,
    output wire          meip,
    output wire          seip
);

    localparam integer NSRC      = 31;                       // レジスタが持つソースの数 (= 1 ワード)
    localparam integer NT        = 2;                        // レジスタを持つターゲットの数
    localparam integer PRIO_N    = 1 << PRIO_BITS;           // 優先度の段数 + 1 (= PPS の bit 数)
    localparam [31:0]  MAX_PRIO  = PRIO_N - 1;
    localparam [31:0]  NUM_SRC32 = NUM_SRC;
    localparam [31:0]  NUM_TGT32 = NUM_TARGET;

    localparam [21:0] A_FEATURE   = 22'h00_0000;
    localparam [21:0] A_PRIO_LAST = 22'h00_007C;              // priority[31]
    localparam [21:0] A_PENDING   = 22'h00_1000;
    localparam [21:0] A_TRIGGER   = 22'h00_1080;
    localparam [21:0] A_NUMBER    = 22'h00_1100;
    localparam [21:0] A_VERSION   = 22'h00_1104;

    // ターゲットごとのレジスタの番地 (= ターゲット t は enable が 0x80、ほかは 0x1000 ずつずれる)
    function [21:0] a_enable(input tt);    a_enable    = tt ? 22'h00_2080 : 22'h00_2000; endfunction
    function [21:0] a_threshold(input tt); a_threshold = tt ? 22'h20_1000 : 22'h20_0000; endfunction
    function [21:0] a_claim(input tt);     a_claim     = tt ? 22'h20_1004 : 22'h20_0004; endfunction
    function [21:0] a_pps(input tt);       a_pps       = tt ? 22'h20_1400 : 22'h20_0400; endfunction

    // 有効なソース (= 1〜NUM_SRC)
    function [NSRC:1] src_mask_f(input integer n);
        integer k;
        begin
            src_mask_f = {NSRC{1'b0}};
            for (k = 1; k <= NSRC; k = k + 1) if (k <= n) src_mask_f[k] = 1'b1;
        end
    endfunction
    localparam [NSRC:1] SRC_MASK = src_mask_f(NUM_SRC);
    localparam [NSRC:1] EDGE     = EDGE_TRIGGER[NSRC:1] & SRC_MASK;

    wire [21:0] waddr = {addr[21:2], 2'b00};
    wire        wfull = wen && (wstrb == 4'hF);

    reg  [1:0]           feature;                // ターゲットに共通 [実機]
    reg  [PRIO_BITS-1:0] prio [1:NSRC];
    reg  [NSRC:1]        pending;
    reg  [NSRC:1]        gw_busy;                // ゲートウェイが complete を待っている
    reg  [NSRC:1]        src_prev;               // エッジを見るための 1 サイクル前の入力
    reg  [NSRC:1]        enable    [0:NT-1];
    reg  [PRIO_BITS-1:0] threshold [0:NT-1];
    reg  [PRIO_N-1:0]    pps       [0:NT-1];

    wire preempt = feature[0];

    // 番地がターゲット t のものか (= NUM_TARGET より後ろのターゲットは無い)
    function tgt_ok(input tt);
        tgt_ok = !tt || (NUM_TARGET > 1);
    endfunction

    // ---------------------------------------------------------
    // ターゲットごとの通知と claim の選択
    // ---------------------------------------------------------
    reg [5:0]           notify_id   [0:NT-1];   // priority > threshold のうち最大 (= 通知)
    reg [PRIO_BITS-1:0] notify_prio [0:NT-1];
    reg [5:0]           any_id      [0:NT-1];   // priority > 0 のうち最大 (= しきい値で絞らない claim)
    reg [PRIO_BITS-1:0] any_prio    [0:NT-1];
    reg [PRIO_BITS-1:0] pps_top     [0:NT-1];   // PPS で最も高い優先度
    integer             i;
    integer             t;
    integer             j;

    always @(*) begin
        for (t = 0; t < NT; t = t + 1) begin
            notify_id[t]   = 6'd0;
            notify_prio[t] = {PRIO_BITS{1'b0}};
            any_id[t]      = 6'd0;
            any_prio[t]    = {PRIO_BITS{1'b0}};
            for (i = 1; i <= NSRC; i = i + 1) begin
                if (tgt_ok(t[0]) && SRC_MASK[i] && pending[i] && enable[t][i]) begin
                    if (prio[i] > threshold[t] && prio[i] > notify_prio[t]) begin
                        notify_id[t]   = i[5:0];
                        notify_prio[t] = prio[i];
                    end
                    if (prio[i] > any_prio[t]) begin
                        any_id[t]   = i[5:0];
                        any_prio[t] = prio[i];
                    end
                end
            end
            pps_top[t] = {PRIO_BITS{1'b0}};
            for (j = 0; j < PRIO_N; j = j + 1) if (pps[t][j]) pps_top[t] = j[PRIO_BITS-1:0];
        end
    end

    // 上で選んだ結果を、毎クロック、レジスタに受ける (= 2026-11-13。31 個から選ぶ回路が、claim と pending の消しと同じ
    // クロックにあり、モックを FPGA のロジックで動かすと AHB_CLK の経路が長かった)。claim と割り込みの線はレジスタの値を
    // 使うので、pending や enable の変化が見えるのは 1 クロック後になる。claim があったクロックには、そのターゲットの
    // レジスタを 0 (= 割り込み無し) にする (= 消した番号が 1 クロック残って、続けて読んだ claim が同じ番号を返さないように)
    reg [5:0]           notify_id_q   [0:NT-1];
    reg [PRIO_BITS-1:0] notify_prio_q [0:NT-1];
    reg [5:0]           any_id_q      [0:NT-1];
    reg [PRIO_BITS-1:0] any_prio_q    [0:NT-1];

    assign meip = (notify_id_q[0] != 6'd0);
    assign seip = (notify_id_q[1] != 6'd0);

    function [5:0] claim_id(input tt);
        claim_id = (CLAIM_ABOVE_THRESHOLD != 0) ? notify_id_q[tt] : any_id_q[tt];
    endfunction
    function [PRIO_BITS-1:0] claim_prio(input tt);
        claim_prio = (CLAIM_ABOVE_THRESHOLD != 0) ? notify_prio_q[tt] : any_prio_q[tt];
    endfunction
    function claimed(input tt);   // このクロックに claim を読んだ (= 番号を返し、その pending を消す)
        claimed = tgt_ok(tt) && ren && waddr == a_claim(tt) && claim_id(tt) != 6'd0;
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (t = 0; t < NT; t = t + 1) begin
                notify_id_q[t]   <= 6'd0;
                notify_prio_q[t] <= {PRIO_BITS{1'b0}};
                any_id_q[t]      <= 6'd0;
                any_prio_q[t]    <= {PRIO_BITS{1'b0}};
            end
        end else begin
            for (t = 0; t < NT; t = t + 1) begin
                notify_id_q[t]   <= claimed(t[0]) ? 6'd0 : notify_id[t];
                notify_prio_q[t] <= claimed(t[0]) ? {PRIO_BITS{1'b0}} : notify_prio[t];
                any_id_q[t]      <= claimed(t[0]) ? 6'd0 : any_id[t];
                any_prio_q[t]    <= claimed(t[0]) ? {PRIO_BITS{1'b0}} : any_prio[t];
            end
        end
    end

    // complete の ID (= 1〜31 で有効なソース。enable は見ない [実機])
    wire [4:0] cmp_id = wdata[4:0];
    wire       cmp_ok = wdata[31:5] == 27'd0 && cmp_id != 5'd0 && SRC_MASK[cmp_id];

    // ---------------------------------------------------------
    // レジスタ
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feature  <= 2'b00;
            for (i = 1; i <= NSRC; i = i + 1) prio[i] <= {{(PRIO_BITS-1){1'b0}}, 1'b1};
            pending  <= {NSRC{1'b0}};
            gw_busy  <= {NSRC{1'b0}};
            src_prev <= {NSRC{1'b0}};
            for (t = 0; t < NT; t = t + 1) begin
                enable[t]    <= {NSRC{1'b0}};
                threshold[t] <= {PRIO_BITS{1'b0}};
                pps[t]       <= {PRIO_N{1'b0}};
            end
        end else begin
            src_prev <= src;

            // ゲートウェイ
            for (i = 1; i <= NSRC; i = i + 1) begin
                if (SRC_MASK[i] && !gw_busy[i] && (EDGE[i] ? (src[i] && !src_prev[i]) : src[i])) begin
                    pending[i] <= 1'b1;
                    gw_busy[i] <= 1'b1;
                end
            end

            // ソフトウェアの書き込み (= complete より前に置き、complete と claim の副作用を優先する)
            if (wfull) begin
                if (waddr == A_FEATURE) feature <= wdata[1:0];
                if (waddr >= 22'h00_0004 && waddr <= A_PRIO_LAST && SRC_MASK[waddr[6:2]]) begin
                    prio[waddr[6:2]] <= wdata[PRIO_BITS-1:0];
                end
                if (waddr == A_PENDING) pending <= pending | (wdata[NSRC:1] & SRC_MASK);
                for (t = 0; t < NT; t = t + 1) begin
                    if (tgt_ok(t[0]) && waddr == a_enable(t[0]))    enable[t]    <= wdata[NSRC:1] & SRC_MASK;
                    if (tgt_ok(t[0]) && waddr == a_threshold(t[0])) threshold[t] <= wdata[PRIO_BITS-1:0];
                    if (tgt_ok(t[0]) && waddr == a_pps(t[0]))       pps[t]       <= wdata[PRIO_N-1:0];
                end
            end

            for (t = 0; t < NT; t = t + 1) begin
                // claim
                if (claimed(t[0])) begin
                    pending[claim_id(t[0])] <= 1'b0;
                    if (preempt) begin
                        pps[t][threshold[t]] <= 1'b1;
                        threshold[t]         <= claim_prio(t[0]);
                    end
                end

                // complete
                if (tgt_ok(t[0]) && wfull && waddr == a_claim(t[0]) && cmp_ok) begin
                    gw_busy[cmp_id] <= 1'b0;
                    if (preempt && pps[t] != {PRIO_N{1'b0}}) begin
                        threshold[t]           <= pps_top[t];
                        pps[t][pps_top[t]]     <= 1'b0;
                    end
                end
            end
        end
    end

    // ---------------------------------------------------------
    // 読み出し
    // ---------------------------------------------------------
    always @(*) begin
        rdata = 32'd0;
        if (waddr == A_FEATURE) rdata = {30'd0, feature};
        if (waddr >= 22'h00_0004 && waddr <= A_PRIO_LAST && SRC_MASK[waddr[6:2]]) begin
            rdata = {{(32-PRIO_BITS){1'b0}}, prio[waddr[6:2]]};
        end
        if (waddr == A_PENDING) rdata = {pending & SRC_MASK, 1'b0};
        if (waddr == A_TRIGGER) rdata = {EDGE, 1'b0};
        if (waddr == A_NUMBER)  rdata = {NUM_TGT32[15:0], NUM_SRC32[15:0]};
        if (waddr == A_VERSION) rdata = {MAX_PRIO[15:0], VERSION};
        for (t = 0; t < NT; t = t + 1) begin
            if (tgt_ok(t[0]) && waddr == a_enable(t[0]))    rdata = {enable[t], 1'b0};
            if (tgt_ok(t[0]) && waddr == a_threshold(t[0])) rdata = {{(32-PRIO_BITS){1'b0}}, threshold[t]};
            if (tgt_ok(t[0]) && waddr == a_claim(t[0]))     rdata = {26'd0, claim_id(t[0])};
            if (tgt_ok(t[0]) && waddr == a_pps(t[0]))       rdata = {{(32-PRIO_N){1'b0}}, pps[t]};
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{addr[1:0], wdata[31:PRIO_BITS], MAX_PRIO[31:16], NUM_SRC32[31:16], NUM_TGT32[31:16]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
