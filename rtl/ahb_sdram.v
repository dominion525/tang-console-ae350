// =============================================================
// File:        rtl/ahb_sdram.v
// Module:      ahb_sdram
// Role:        AE350 の DDR_H* (64 ビット AHB) を、SDRAM コントローラ (rtl/sdram_bridge.v) につなぐブリッジ。
//              ファブリック側の回路で、シミュレーションでも実機でも使う。
//
//   hclk (DDR_CLK) 側                               sclk (SDRAM のクロック) 側
//   AE350 の転送を受け付けて保持し、トグルで渡す ───▶  読み出し: アドレスを含む 16 バイトのラインを読み、アドレスのビット 3 で 8 バイトを選ぶ
//                                                  書き込み: 8 バイトと、HSIZE とアドレスで決まるバイトの有効 (wmask) を 1 回で渡す
//   応答を受けて AE350 に返す              ◀───  完了したらトグルで返す
//
//   - AE350 に返す HREADYOUT、HRDATA、HRESP はレジスタ出力 (APB_P* と EXTS_H* で、AE350 との往復の経路が
//     実機でタイミングを満たさなかったのと同じ理由)
//   - 転送は 1 つずつ処理する。HREADYOUT = 0 の間、AE350 は次の転送を出さない
//   - SDRAM の範囲 (2^SDRAM_AW バイト) 外のアドレスには、SDRAM にアクセスせずにエラー応答 (2 サイクル) を返す。ただし
//     STAT_BASE からの 32 バイトは、読み書きにかかった時間を数えるカウンタ (下の表。読み出すと値を返し、書き込みは無視する)
//   - カウンタはクリアしない (読む側が前後の差を取る)。SDRAM のクロック側のカウンタは、転送がない間は変わらない
//     (転送は 1 つずつで、カウンタを読む転送は SDRAM にアクセスしない) ので、s_rdata と同じく DDR_CLK 側でそのまま読む
//
//     +0x00 読み出し転送の数                      +0x04 読み出しで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x08 書き込み転送の数                      +0x0C 書き込みで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x10 ライン読み出しの sclk のサイクル数の合計  +0x14 書き込みの sclk のサイクル数の合計
//     +0x18 SDRAM に書き込んだバイト数              +0x1C 0
//   - sdram_bridge は初期化が終わるまで読み書きを受け付けないので、その間の転送は待たされるだけ
//   - アドレスの幅とクロックは、パラメータと上位のトップで決める (SDRAM コントローラを差し替えやすいように、
//     sclk 側は SDRAM コントローラのインターフェース (fill_*、we、waddr、wdata、wmask、wready) だけを使う)
//
// Ports:
//   input  wire hclk / hresetn            DDR_CLK と、AE350 が出力する DDR_RSTN
//   AHB スレーブ (DDR_H*。hready は AE350 の DDR_HREADY で、この回路の hreadyout と同じ)
//   input  wire sclk / srst_n              SDRAM のクロックと、その側のリセット (sclk に同期済み)
//   SDRAM コントローラ (sdram_bridge か sdram_ctrl_hs) との接続ポート (fill_*、we、waddr、wdata、wmask、wready)
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

    reg [2:0]  h_st;
    reg [31:0] q_addr;
    reg        q_write;
    reg [2:0]  q_size;
    reg [63:0] q_wdata;
    reg        req_t;                 // 渡すたびに反転する
    reg [1:0]  ack_s;                 // SDRAM 側の ack_t を 2 段の FF で受ける
    reg        ack_seen;              // 最後に受けた ack_t

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
    wire h_busy = !hreadyout && ((h_st == H_DATA && in_range) || h_st == H_WAIT);

    function [63:0] stat_word(input [1:0] i);
        case (i)
            2'd0:    stat_word = {st_rd_cyc, st_rd_n};
            2'd1:    stat_word = {st_wr_cyc, st_wr_n};
            2'd2:    stat_word = {st_s_wr_cyc, st_s_rd_cyc};
            default: stat_word = {32'd0, st_s_wr_bytes};
        endcase
    endfunction

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
                    if (in_range) begin
                        req_t <= ~req_t;
                        h_st  <= H_WAIT;
                        if (q_write) st_wr_n <= st_wr_n + 32'd1;
                        else         st_rd_n <= st_rd_n + 32'd1;
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
    reg [1:0] req_s;                  // hclk 側の req_t を 2 段の FF で受ける
    reg       req_seen;
    reg       ack_t;
    reg [3:0] wbytes;                 // 書き込むバイト数 (wmask の 1 の数。カウンタに足す値を、wmask と一緒に決めておく)

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

    assign fill_line = q_addr[SDRAM_AW-1:4];
    assign waddr     = {q_addr[SDRAM_AW-1:3], 3'b000};

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
            s_rdata    <= 64'd0;
            st_s_rd_cyc   <= 32'd0;
            st_s_wr_cyc   <= 32'd0;
            st_s_wr_bytes <= 32'd0;
        end else begin
            req_s <= {req_s[0], req_t};
            // 書き込む値とバイトの有効は、取り込みの条件を付けずに毎クロック写す。q_* は要求のトグルと同じエッジで決まり、
            // こちらが応答を返して次の転送が来るまで変わらないので、we が 1 の間 (SDRAM コントローラが見る間) は変わらない。
            // 条件を付けると、64 ビットの wdata などに取り込みの許可を配る配線が長くなり、s_clk の余裕を削っていた
            wdata  <= q_wdata;
            wmask  <= lanes(q_addr[2:0], q_size);
            wbytes <= ones(lanes(q_addr[2:0], q_size));
            if (s_st == S_READ)            st_s_rd_cyc   <= st_s_rd_cyc + 32'd1;
            if (s_st == S_WRITE)           st_s_wr_cyc   <= st_s_wr_cyc + 32'd1;
            if (s_st == S_WRITE && wready) st_s_wr_bytes <= st_s_wr_bytes + {28'd0, wbytes};
            case (s_st)
                S_IDLE: begin
                    if (req_new) begin
                        req_seen <= req_s[1];
                        if (q_write) begin
                            we    <= 1'b1;
                            s_st  <= S_WRITE;
                        end else begin
                            fill_valid <= 1'b1;
                            s_st       <= S_READ;
                        end
                    end
                end
                S_READ: begin
                    if (fill_ready) begin
                        fill_valid <= 1'b0;
                        s_rdata    <= q_addr[3] ? fill_data[127:64] : fill_data[63:0];
                        ack_t      <= ~ack_t;
                        s_st       <= S_IDLE;
                    end
                end
                default: begin
                    // SDRAM コントローラが受け付けたら (wready)、応答を返す
                    if (wready) begin
                        we    <= 1'b0;
                        ack_t <= ~ack_t;
                        s_st  <= S_IDLE;
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
