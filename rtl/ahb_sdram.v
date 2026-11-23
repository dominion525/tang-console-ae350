// =============================================================
// File:        rtl/ahb_sdram.v
// Module:      ahb_sdram
// Role:        AE350 の DDR_H* (64 ビット AHB) を、SDRAM コントローラ (rtl/sdram_ctrl_hs.v) につなぐブリッジ。
//              ファブリック側の回路で、シミュレーションでも実機でも使う。
//
//   hclk (DDR_CLK) 側                               sclk (SDRAM のクロック) 側
//   読み出し: 受け付けて保持し、トグルで渡す ───▶  アドレスを含む 16 バイトのラインを読み、アドレスのビット 3 で 8 バイトを選ぶ
//             応答を受けて AE350 に返す     ◀───  完了したらトグルで返す
//   書き込み: 書き込みのバッファ (非同期の FIFO) に入れ、すぐ AE350 に返す ───▶  バッファから 1 段ずつ取り出し、8 バイトと
//             バイトの有効 (wmask) を SDRAM コントローラに渡す
//
//   - AE350 に返す HREADYOUT、HRDATA、HRESP はレジスタ出力 (APB_P* と EXTS_H* で、AE350 との往復の経路が
//     実機でタイミングを満たさなかったのと同じ理由)
//   - 転送は 1 つずつ受け付ける。HREADYOUT = 0 の間、AE350 は次の転送を出さない
//   - 書き込みのバッファ (16 段): SDRAM の範囲の書き込みは、バッファに空きがあれば入れた時点で OKAY を返す (データフェーズの
//     1 サイクルで終わる。満杯なら空くまで待たせる)。DDR_H* の書き込みはすべて bufferable として扱う (範囲内の書き込みは必ず
//     成功し、範囲外はバッファに入れる前にエラー応答を返すので、先に返した OKAY が後で覆ることはない)。非同期の FIFO は
//     Cummings の方式 (グレイコードのポインタを 2 段の FF で相手側に渡し、満杯と空は、受けた相手のポインタと比べて決める)
//   - 読み出し (SDRAM の範囲とカウンタ) は、書き込みのバッファが空になる (前の書き込みを SDRAM コントローラが受け付ける) まで
//     待ってから行う。後から読んだ値は、前に書いた値と食い違わない。表示の回路のように SDRAM を直接読む回路は、バッファに残る
//     書き込みを追い越して読むことがあるので、CPU は描き終えたら SDRAM の範囲を 1 回読んでから表示を切り替える (sw/fb.h の fb_sync)
//   - SDRAM の範囲 (2^SDRAM_AW バイト) 外のアドレスには、SDRAM にアクセスせずにエラー応答 (2 サイクル) を返す。ただし
//     STAT_BASE からの 32 バイトは、読み書きにかかった時間を数えるカウンタ (下の表。読み出すと値を返し、書き込みは無視する)
//   - カウンタはクリアしない (読む側が前後の差を取る)。SDRAM のクロック側のカウンタは、転送がない間は変わらない
//     (転送は 1 つずつで、カウンタを読む転送は SDRAM にアクセスしない) ので、s_rdata と同じく DDR_CLK 側でそのまま読む
//
//     +0x00 読み出し転送の数                      +0x04 読み出しで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x08 書き込み転送の数                      +0x0C 書き込みで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x10 ライン読み出しの sclk のサイクル数の合計  +0x14 書き込みの sclk のサイクル数の合計
//     +0x18 SDRAM に書き込んだバイト数              +0x1C 0
//   - sdram_ctrl_hs は初期化が終わるまで読み書きを受け付けないので、その間の転送は待たされるだけ
//   - アドレスの幅とクロックは、パラメータと上位のトップで決める (SDRAM コントローラを差し替えやすいように、
//     sclk 側は SDRAM コントローラのインターフェース (fill_*、we、waddr、wdata、wmask、wready) だけを使う)
//
// Ports:
//   input  wire hclk / hresetn            DDR_CLK と、AE350 が出力する DDR_RSTN
//   AHB スレーブ (DDR_H*。hready は AE350 の DDR_HREADY で、この回路の hreadyout と同じ)
//   input  wire sclk / srst_n              SDRAM のクロックと、その側のリセット (sclk に同期済み)
//   SDRAM コントローラ (sdram_ctrl_hs) との接続ポート (fill_*、we、waddr、wdata、wmask、wready)
//
// Parameters:
//   SDRAM_AW   SDRAM のバイトアドレスの幅 (25 なら 32 MB、W9825G6KH 1 個)
//   STAT_BASE  カウンタのアドレス (SDRAM の範囲外、32 バイト境界)
//
// デバッグ用のトレース (マクロ AHB_SDRAM_TRACE を定義したときだけ入る。既定のビルドとシミュレーションには入らない):
//   受け付けたアドレスフェーズを 256 個まで記録する (本物の AE350 が DDR_H* に出す転送を調べるため)
//     STAT_BASE + 0x1000          書き込むと記録を始める (数を 0 に戻す。256 個で止まる)。読み出すと、記録した数を返す
//     STAT_BASE + 0x2000 + 8 * i  i 番目の記録。下位 32 ビットは HADDR。上位 32 ビットは bit 0 HWRITE、bit 3〜1 HSIZE、
//                                 bit 5〜4 HTRANS、bit 31〜8 DDR_CLK で数えた時刻
//   使い方: board/tang_console/build.sh に TRACE=1 を付けてビルドする。CPU のプログラムから STAT_BASE + 0x1000 に書き込んで
//   記録を始め、調べたい処理の後で、数と記録を読み出す。トレースの回路がないビルドでは、このアドレスはエラー応答になる
//   使用例: カウンタの書き込み転送の数が 2〜3 個ずれたとき、記録から、AE350 が出す転送はすべて 32 ビットの NONSEQ
//   (書き込みの結合もバーストもない) と分かった。ずれの原因は、N25F の書き込みバッファをカウンタの読み出しが追い越した
//   ことだと切り分けた (sw/probe.c の sdram_stat の fence)
// =============================================================

`default_nettype none

module ahb_sdram #(
    parameter integer SDRAM_AW = 25,
    parameter [31:0]  STAT_BASE = 32'h0300_0000
) (
    // DDR_CLK 側
    input  wire                 hclk,
    input  wire                 hresetn,
    input  wire [31:0]          haddr,
    input  wire [1:0]           htrans,
    input  wire                 hwrite,
    input  wire [2:0]           hsize,
    input  wire [63:0]          hwdata,
    output reg  [63:0]          hrdata,
    output reg                  hreadyout,
    output reg                  hresp,

    // SDRAM のクロック側
    input  wire                 sclk,
    input  wire                 srst_n,
    output reg                  fill_valid,
    output wire [SDRAM_AW-5:0]  fill_line,
    input  wire                 fill_ready,
    input  wire [127:0]         fill_data,
    output reg                  we,
    output wire [SDRAM_AW-1:0]  waddr,         // 8 バイト境界 (下位 3 ビットは 0)
    output reg  [63:0]          wdata,
    output reg  [7:0]           wmask,         // 書き込むバイト (1 のバイトだけ書き込む。wdata のバイトレーンと同じ並び)
    input  wire                 wready
);

    // ---------------------------------------------------------
    // DDR_CLK 側: 受け付けて保持し、sclk 側に渡す
    // ---------------------------------------------------------
    localparam [2:0] H_RDY  = 3'd0;   // HREADYOUT = 1。アドレスフェーズを受け付けられる
    localparam [2:0] H_DATA = 3'd1;   // データフェーズの 1 サイクル目 (書き込む値を保持する)
    localparam [2:0] H_WAIT = 3'd2;   // SDRAM 側の応答を待つ
    localparam [2:0] H_ERR1 = 3'd3;   // エラー応答の 1 サイクル目
    localparam [2:0] H_WFULL = 3'd4;  // 書き込みのバッファが満杯で、空くのを待つ
    localparam [2:0] H_DRAIN = 3'd5;  // 読み出しの前に、書き込みのバッファが空になるのを待つ

    reg [2:0]  h_st;
    reg [31:0] q_addr;
    reg        q_write;
    reg [2:0]  q_size;
    reg [63:0] q_wdata;
    reg        req_t;                 // 渡すたびに反転する
    reg [1:0]  ack_s;                 // SDRAM 側の ack_t を 2 段の FF で受ける
    reg        ack_seen;              // 最後に受けた ack_t

    // 書き込みのバッファ (DDR_CLK 側から SDRAM のクロック側への非同期の FIFO。1 段は {8 バイト境界のアドレス, データ, バイトの有効})
    localparam integer WF_AW = 4;                          // 16 段
    localparam integer WF_W  = (SDRAM_AW - 3) + 64 + 8;
    reg [WF_W-1:0] wf_mem [0:(1 << WF_AW) - 1];
    reg [WF_AW:0]  wf_wbin, wf_wgray;                      // 書き込み側のポインタ (DDR_CLK)
    reg [WF_AW:0]  wf_rbin, wf_rgray;                      // 読み出し側のポインタ (SDRAM のクロック)
    reg [WF_AW:0]  wf_rgray_s1, wf_rgray_s2;               // 読み出し側のポインタを DDR_CLK で 2 段受ける
    reg [WF_AW:0]  wf_wgray_s1, wf_wgray_s2;               // 書き込み側のポインタを SDRAM のクロックで 2 段受ける
    wire [WF_AW:0] wf_wbin_nx = wf_wbin + 1'b1;
    wire [WF_AW:0] wf_rbin_nx = wf_rbin + 1'b1;
    wire           wf_full    = (wf_wgray == {~wf_rgray_s2[WF_AW:WF_AW-1], wf_rgray_s2[WF_AW-2:0]});
    wire           wf_empty_h = (wf_wgray == wf_rgray_s2);  // SDRAM 側がすべて取り出した (DDR_CLK 側から見て)

    wire in_range = (q_addr[31:SDRAM_AW] == {(32-SDRAM_AW){1'b0}});
    wire ack_new  = (ack_s[1] != ack_seen);
    wire in_stat  = (q_addr[31:5] == STAT_BASE[31:5]);
`ifdef AHB_SDRAM_TRACE
    // デバッグ用のトレース: 受け付けた転送の記録
    wire       in_tr_ctl = (q_addr[31:3] == STAT_BASE[31:3] + 29'h200);     // STAT_BASE + 0x1000
    wire       in_tr_buf = (q_addr[31:11] == STAT_BASE[31:11] + 21'd4);   // STAT_BASE + 0x2000〜0x27FF
    reg [63:0] tr_mem [0:255];
    reg [8:0]  tr_n;
    reg        tr_on;
    reg [23:0] tr_time;
    wire       tr_we = tr_on && (h_st == 3'd0) && htrans[1];
    always @(posedge hclk) begin
        if (tr_we) tr_mem[tr_n[7:0]] <= {tr_time, 2'b00, htrans, hsize, hwrite, haddr};
    end
`endif

    // カウンタ (DDR_CLK 側)
    reg [31:0] st_rd_n, st_rd_cyc, st_wr_n, st_wr_cyc;
    // カウンタ (SDRAM のクロック側)
    reg [31:0] st_s_rd_cyc, st_s_wr_cyc, st_s_wr_bytes;

    // SDRAM にアクセスする転送で、AE350 を待たせているサイクル
    wire h_busy = !hreadyout && ((h_st == H_DATA && in_range) || h_st == H_WAIT || h_st == H_WFULL || (h_st == H_DRAIN && in_range));

    function [63:0] stat_word(input [1:0] i);
        case (i)
            2'd0:    stat_word = {st_rd_cyc, st_rd_n};
            2'd1:    stat_word = {st_wr_cyc, st_wr_n};
            2'd2:    stat_word = {st_s_wr_cyc, st_s_rd_cyc};
            default: stat_word = {32'd0, st_s_wr_bytes};
        endcase
    endfunction

    // 書き込みのバッファに入れる: データフェーズで空きがあればそのとき (HWDATA)、満杯で待ったら空いたとき (保持した値)
    wire wf_push_d = (h_st == H_DATA) && in_range && q_write && !wf_full;
    wire wf_push_w = (h_st == H_WFULL) && !wf_full;
    always @(posedge hclk) begin
        if (wf_push_d) wf_mem[wf_wbin[WF_AW-1:0]] <= {q_addr[SDRAM_AW-1:3], hwdata, lanes(q_addr[2:0], q_size)};
        if (wf_push_w) wf_mem[wf_wbin[WF_AW-1:0]] <= {q_addr[SDRAM_AW-1:3], q_wdata, lanes(q_addr[2:0], q_size)};
    end

    // SDRAM 側が読み出した値 (次の要求まで変わらないので、ack を受けてから hclk で読む)
    reg [63:0] s_rdata;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            h_st      <= H_RDY;
            hreadyout <= 1'b1;
            hresp     <= 1'b0;
            hrdata    <= 64'd0;
            q_addr    <= 32'd0;
            q_write   <= 1'b0;
            q_size    <= 3'd0;
            q_wdata   <= 64'd0;
            req_t     <= 1'b0;
            ack_s     <= 2'b00;
            ack_seen  <= 1'b0;
            wf_wbin   <= {(WF_AW+1){1'b0}};
            wf_wgray  <= {(WF_AW+1){1'b0}};
            wf_rgray_s1 <= {(WF_AW+1){1'b0}};
            wf_rgray_s2 <= {(WF_AW+1){1'b0}};
`ifdef AHB_SDRAM_TRACE
            tr_n      <= 9'd0;
            tr_on     <= 1'b0;
            tr_time   <= 24'd0;
`endif
            st_rd_n   <= 32'd0;
            st_rd_cyc <= 32'd0;
            st_wr_n   <= 32'd0;
            st_wr_cyc <= 32'd0;
        end else begin
            ack_s <= {ack_s[0], ack_t};
            wf_rgray_s1 <= wf_rgray;
            wf_rgray_s2 <= wf_rgray_s1;
`ifdef AHB_SDRAM_TRACE
            tr_time <= tr_time + 24'd1;
            if (tr_we) begin
                tr_n <= tr_n + 9'd1;
                if (tr_n == 9'd255) tr_on <= 1'b0;
            end
`endif
            if (h_busy) begin
                if (q_write) st_wr_cyc <= st_wr_cyc + 32'd1;
                else         st_rd_cyc <= st_rd_cyc + 32'd1;
            end
            case (h_st)
                H_RDY: begin
                    hresp <= 1'b0;
                    if (htrans[1]) begin
                        q_addr    <= haddr;
                        q_write   <= hwrite;
                        q_size    <= hsize;
                        hreadyout <= 1'b0;
                        h_st      <= H_DATA;
                    end
                end
                H_DATA: begin
                    q_wdata <= hwdata;
                    if (in_range && q_write) begin
                        // 書き込み: バッファに空きがあれば入れて終わる (入れるのは上の wf_push_d)。満杯なら H_WFULL で待つ
                        if (!wf_full) begin
                            wf_wbin   <= wf_wbin_nx;
                            wf_wgray  <= wf_wbin_nx ^ (wf_wbin_nx >> 1);
                            st_wr_n   <= st_wr_n + 32'd1;
                            hreadyout <= 1'b1;
                            h_st      <= H_RDY;
                        end else begin
                            h_st <= H_WFULL;
                        end
                    end else if ((in_range || in_stat) && !wf_empty_h) begin
                        // 読み出しとカウンタ: 書き込みのバッファが空になるまで待ち、H_DATA でもう一度判定する (q_wdata は使わない)
                        h_st <= H_DRAIN;
                    end else if (in_range) begin
                        req_t   <= ~req_t;
                        h_st    <= H_WAIT;
                        st_rd_n <= st_rd_n + 32'd1;
`ifdef AHB_SDRAM_TRACE
                    end else if (in_tr_ctl) begin
                        // デバッグ用のトレース: 書き込むと記録を始め、読み出すと記録した数を返す
                        if (q_write) begin
                            tr_n  <= 9'd0;
                            tr_on <= 1'b1;
                        end
                        hrdata    <= {23'd0, tr_n, 23'd0, tr_n};
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                    end else if (in_tr_buf) begin
                        hrdata    <= tr_mem[q_addr[10:3]];
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
`endif
                    end else if (in_stat) begin
                        // カウンタ: 読み出すと値を返し、書き込みは無視する (どちらも OKAY)
                        hrdata    <= stat_word(q_addr[4:3]);
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                    end else begin
                        hresp <= 1'b1;
                        h_st  <= H_ERR1;
                    end
                end
                H_WAIT: begin
                    if (ack_new) begin
                        ack_seen  <= ack_s[1];
                        hrdata    <= s_rdata;
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                    end
                end
                H_WFULL: begin
                    // バッファに空きができたら、保持した書き込みを入れて (上の wf_push_w) 終わる
                    if (!wf_full) begin
                        wf_wbin   <= wf_wbin_nx;
                        wf_wgray  <= wf_wbin_nx ^ (wf_wbin_nx >> 1);
                        st_wr_n   <= st_wr_n + 32'd1;
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                    end
                end
                H_DRAIN: begin
                    if (wf_empty_h) h_st <= H_DATA;
                end
                default: begin
                    // エラー応答の 2 サイクル目 (HRESP = 1 のまま HREADYOUT = 1)
                    hreadyout <= 1'b1;
                    h_st      <= H_RDY;
                end
            endcase
        end
    end

    // ---------------------------------------------------------
    // SDRAM のクロック側: 1 つの転送を、ライン読み出し 1 回か、8 バイトとバイトの有効 (wmask) の書き込み 1 回にする
    // ---------------------------------------------------------
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_READ  = 2'd1;
    localparam [1:0] S_WRITE = 2'd2;

    reg [1:0] s_st;
    // 読み出しを待っている (s_st == S_READ と同じ値)。2 つ持ち、それぞれ s_rdata の 32 ビットずつの取り込み許可に配る (s_st と
    // fill_ready から 64 個に配る配線が長く、表示の回路をつないだ構成で s_clk の余裕がなくなったため)。待っている間は毎クロック
    // 取り込み、fill_ready のエッジで最後の値を取り込んで止まる (hclk 側が s_rdata を読むのは ack_t が変わった後)
    reg [1:0] s_rd_wait /* synthesis syn_preserve = 1 */;
    reg [1:0] req_s;                  // hclk 側の req_t を 2 段の FF で受ける
    reg       req_seen;
    reg       ack_t;
    reg [3:0] wbytes;                 // 書き込むバイト数 (wmask の 1 の数。カウンタに足す値を、wmask と一緒に決めておく)
    reg [SDRAM_AW-4:0] w_line;        // 書き込む 8 バイト境界のアドレス
    // 書き込みのバッファの先頭の段。記憶部分をブロック RAM にするため、読み出しはクロックに合わせる (毎クロック、取り出す位置の段を
    // 読んでレジスタに受ける。非同期に読む書き方では、合成でレジスタと選択回路に展開され、s_clk の余裕もなくなった)
    reg  [WF_W-1:0] wf_q;
    wire s_wf_empty = (wf_rgray == wf_wgray_s2);
    // 先頭の段の値が wdata などにそろっている。取り出す位置が変わるか、空から段が入ってから、wf_q と wdata の 2 クロックを待つ
    reg  [1:0] wf_avail;

    wire req_new = (req_s[1] != req_seen);

    // HSIZE とアドレスの下位から、書き込むバイトレーンを決める (64 ビットバスのバイトレーン)
    function [7:0] lanes(input [2:0] a, input [2:0] size);
        case (size)
            3'd0:    lanes = 8'b0000_0001 << a;
            3'd1:    lanes = 8'b0000_0011 << {a[2:1], 1'b0};
            3'd2:    lanes = 8'b0000_1111 << {a[2], 2'b00};
            default: lanes = 8'b1111_1111;
        endcase
    endfunction

    // バイトの有効のうち 1 の数 (書き込んだバイト数のカウンタに足す)
    function [3:0] ones(input [7:0] m);
        integer k;
        begin
            ones = 4'd0;
            for (k = 0; k < 8; k = k + 1) ones = ones + {3'd0, m[k]};
        end
    endfunction

    always @(posedge sclk) begin
        wf_q <= wf_mem[wf_rbin[WF_AW-1:0]];
    end

    assign fill_line = q_addr[SDRAM_AW-1:4];
    assign waddr     = {w_line, 3'b000};

    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            s_st       <= S_IDLE;
            req_s      <= 2'b00;
            req_seen   <= 1'b0;
            ack_t      <= 1'b0;
            fill_valid <= 1'b0;
            we         <= 1'b0;
            wdata      <= 64'd0;
            wmask      <= 8'd0;
            wbytes     <= 4'd0;
            w_line     <= {(SDRAM_AW-3){1'b0}};
            wf_rbin    <= {(WF_AW+1){1'b0}};
            wf_rgray   <= {(WF_AW+1){1'b0}};
            wf_wgray_s1 <= {(WF_AW+1){1'b0}};
            wf_wgray_s2 <= {(WF_AW+1){1'b0}};
            wf_avail   <= 2'b00;
            s_rdata    <= 64'd0;
            s_rd_wait  <= 2'b00;
            st_s_rd_cyc   <= 32'd0;
            st_s_wr_cyc   <= 32'd0;
            st_s_wr_bytes <= 32'd0;
        end else begin
            req_s <= {req_s[0], req_t};
            wf_wgray_s1 <= wf_wgray;
            wf_wgray_s2 <= wf_wgray_s1;
            wf_avail    <= {wf_avail[0] && !s_wf_empty, !s_wf_empty};   // 取り出したエッジでは、下で 0 に戻す
            // 書き込む値、アドレス、バイトの有効は、書き込みのバッファの先頭の段から、取り込みの条件を付けずに毎クロック写す。
            // 先頭の段は、取り出す (wf_rbin を進める) まで変わらないので、we が 1 の間 (SDRAM コントローラが見る間) は変わらない。
            // 条件を付けると、64 ビットの wdata などに取り込みの許可を配る配線が長くなり、s_clk の余裕を削っていた
            wdata  <= wf_q[71:8];
            wmask  <= wf_q[7:0];
            wbytes <= ones(wf_q[7:0]);
            w_line <= wf_q[WF_W-1:72];
            if (s_st == S_READ)            st_s_rd_cyc   <= st_s_rd_cyc + 32'd1;
            if (s_st == S_WRITE)           st_s_wr_cyc   <= st_s_wr_cyc + 32'd1;
            if (s_st == S_WRITE && wready) st_s_wr_bytes <= st_s_wr_bytes + {28'd0, wbytes};
            if (s_rd_wait[0]) s_rdata[31:0]  <= q_addr[3] ? fill_data[95:64]  : fill_data[31:0];
            if (s_rd_wait[1]) s_rdata[63:32] <= q_addr[3] ? fill_data[127:96] : fill_data[63:32];
            case (s_st)
                S_IDLE: begin
                    // 読み出しの要求は、DDR_CLK 側が書き込みのバッファが空になってから出すので、書き込みと重ならない
                    if (req_new) begin
                        req_seen   <= req_s[1];
                        fill_valid <= 1'b1;
                        s_rd_wait  <= 2'b11;
                        s_st       <= S_READ;
                    end else if (wf_avail[1]) begin
                        we   <= 1'b1;
                        s_st <= S_WRITE;
                    end
                end
                S_READ: begin
                    if (fill_ready) begin
                        fill_valid <= 1'b0;
                        s_rd_wait  <= 2'b00;
                        ack_t      <= ~ack_t;
                        s_st       <= S_IDLE;
                    end
                end
                default: begin
                    // SDRAM コントローラが受け付けたら (wready)、書き込みのバッファの先頭の段を取り出す
                    if (wready) begin
                        we       <= 1'b0;
                        wf_rbin  <= wf_rbin_nx;
                        wf_rgray <= wf_rbin_nx ^ (wf_rbin_nx >> 1);
                        wf_avail <= 2'b00;
                        s_st     <= S_IDLE;
                    end
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = htrans[0];   // NONSEQ と SEQ を区別しない (どちらも 1 つの転送として受け付ける)
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
