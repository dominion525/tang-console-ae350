// =============================================================
// File:        rtl/ahb_litedram.v
// Module:      ahb_litedram
// Role:        AE350 の DDR_H* (64 ビット AHB) を、LiteDRAM の DDR3 コントローラ (litedram_gen が生成する litedram_core の
//              native ポート) につなぐブリッジ (board/tang_console/build.sh の MEM=litedram)。構成は ahb_ddr3.v と同じ。
//
//   hclk (DDR_CLK) 側                               cclk (LiteDRAM の user_clk) 側
//   AE350 の転送を受け付けて保持し、トグルで渡す ───▶  読み出し: アドレスを含む native ポートの 1 ワード (2^LINE_AW バイト) を
//                                                       読み、8 バイトを選ぶ
//                                                  書き込み: 1 ワードのうち、HSIZE とアドレスで決まるバイトだけを書き込む (wdata_we)
//   応答を受けて AE350 に返す              ◀───  完了したらトグルで返す
//
//   - native ポートは、コマンド (cmd_valid と cmd_ready、cmd_we、cmd_addr)、書き込みデータ (wdata_valid と wdata_ready)、
//     読み出しデータ (rdata_valid と rdata_ready) の 3 組の valid と ready からなる。アドレスは 1 ワード単位 (DDR3 1 個なら 16 バイト、
//     2 個なら 32 バイト。どちらも 25 ビット)
//   - 直前に読み出した 1 ワードを保持し、同じワードの読み出しは LiteDRAM にアクセスせずに返す。同じワードへの書き込みでは、
//     保持した値も更新する (ahb_ddr3.v と同じ方式)
//   - LiteDRAM の初期化とレベリング (init_done) が終わるまで、cclk 側は転送を受け付けない (AE350 は待たされるだけ)
//   - AE350 に返す HREADYOUT、HRDATA、HRESP はレジスタ出力。転送は 1 つずつ処理する
//   - DDR3 の範囲 (2^MEM_AW バイト) 外のアドレスにはエラー応答を返す。ただし STAT_BASE からの 32 バイトは時間計測用の
//     カウンタ (ahb_ddr3.v と同じ配置なので、sw/mem_bench.c がそのまま読める)
//
//     +0x00 読み出し転送の数                          +0x04 読み出しで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x08 書き込み転送の数                          +0x0C 書き込みで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x10 読み出しコマンドを出してから受け付けられる  +0x14 読み出しコマンドが受け付けられてから読み出しデータが
//           までの cclk のサイクル数の合計                  届くまでの cclk のサイクル数の合計
//     +0x18 書き込みコマンドとデータが受け付けられる    +0x1C 保持した 1 ワードから返した読み出しの数
//           までの cclk のサイクル数の合計
//
// Ports:
//   input  wire hclk / hresetn            DDR_CLK と、AE350 が出力する DDR_RSTN
//   AHB スレーブ (DDR_H*。hready は AE350 の DDR_HREADY で、この回路の hreadyout と同じ)
//   input  wire cclk / crst_n             LiteDRAM の user_clk と、その側のリセット (init_done かつ !user_rst)
//   LiteDRAM の native ポート (cmd_*、wdata_*、rdata_*)
// =============================================================

`default_nettype none

module ahb_litedram #(
    parameter [31:0]  STAT_BASE = 32'h7F00_0000,
    parameter integer MEM_AW    = 30,   // DDR3 のバイトアドレスの幅 (30 なら 1 GB で DDR3 2 個、29 なら 512 MB で 1 個)
    parameter integer LINE_AW   = 5     // native ポートの 1 ワードのバイト数の log2 (5 なら 32 バイトで DQ 32 ビット、4 なら 16 バイトで DQ 16 ビット)
) (
    // DDR_CLK 側
    input  wire         hclk,
    input  wire         hresetn,
    input  wire [31:0]  haddr,
    input  wire [1:0]   htrans,
    input  wire         hwrite,
    input  wire [2:0]   hsize,
    input  wire [63:0]  hwdata,
    output reg  [63:0]  hrdata,
    output reg          hreadyout,
    output reg          hresp,

    // LiteDRAM 側
    input  wire         cclk,
    input  wire         crst_n,
    output reg          cmd_valid,
    input  wire         cmd_ready,
    output reg          cmd_we,
    output reg  [MEM_AW-LINE_AW-1:0] cmd_addr,
    output reg          wdata_valid,
    input  wire         wdata_ready,
    output reg  [(8<<LINE_AW)-1:0] wdata_data,
    output reg  [(1<<LINE_AW)-1:0] wdata_we,
    input  wire         rdata_valid,
    output wire         rdata_ready,
    input  wire [(8<<LINE_AW)-1:0] rdata_data
);

    // ---------------------------------------------------------
    // DDR_CLK 側: 受け付けて保持し、cclk 側に渡す
    // ---------------------------------------------------------
    localparam [1:0] H_RDY  = 2'd0;
    localparam [1:0] H_DATA = 2'd1;
    localparam [1:0] H_WAIT = 2'd2;
    localparam [1:0] H_ERR1 = 2'd3;

    reg [1:0]  h_st;
    reg [31:0] q_addr;
    reg        q_write;
    reg [2:0]  q_size;
    reg [63:0] q_wdata;
    reg        req_t;
    reg [1:0]  ack_s;
    reg        ack_seen;
    reg        ack_t;
    localparam integer DW = 8 << LINE_AW;   // native ポートの 1 ワードのビット数
    localparam integer TW = MEM_AW - LINE_AW;
    reg [DW-1:0] c_rline;              // cclk 側が読み出した 1 ワード (次の要求まで変わらないので、ack を受けてから hclk で読む)

    wire in_range = (q_addr[31:MEM_AW] == {(32-MEM_AW){1'b0}});
    wire [LINE_AW-4:0] q_lane = q_addr[LINE_AW-1:3];   // 1 ワードの中での 8 バイトの位置
    wire ack_new  = (ack_s[1] != ack_seen);
    wire in_stat  = (q_addr[31:5] == STAT_BASE[31:5]);

    reg         line_valid;
    reg [TW-1:0] line_tag;            // バイトアドレスのビット MEM_AW-1〜LINE_AW
    reg [DW-1:0] line_data;
    wire         line_hit = line_valid && (line_tag == q_addr[MEM_AW-1:LINE_AW]);

    reg [31:0] st_rd_n, st_rd_cyc, st_wr_n, st_wr_cyc, st_hit;
    reg [31:0] st_c_rwait, st_c_rlat, st_c_wwait;
    wire h_busy = !hreadyout && ((h_st == H_DATA && in_range) || h_st == H_WAIT);

    function [63:0] stat_word(input [1:0] i);
        case (i)
            2'd0:    stat_word = {st_rd_cyc, st_rd_n};
            2'd1:    stat_word = {st_wr_cyc, st_wr_n};
            2'd2:    stat_word = {st_c_rlat, st_c_rwait};
            default: stat_word = {st_hit, st_c_wwait};
        endcase
    endfunction

    // HSIZE とアドレスの下位から、書き込むバイトを決める (64 ビットバスのバイトレーン)
    function [7:0] lanes(input [2:0] a, input [2:0] size);
        case (size)
            3'd0:    lanes = 8'b0000_0001 << a;
            3'd1:    lanes = 8'b0000_0011 << {a[2:1], 1'b0};
            3'd2:    lanes = 8'b0000_1111 << {a[2], 2'b00};
            default: lanes = 8'b1111_1111;
        endcase
    endfunction

    wire [7:0] h_lanes = lanes(q_addr[2:0], q_size);
    reg [DW-1:0] line_merged;
    integer     k;
    always @(*) begin
        line_merged = line_data;
        for (k = 0; k < 8; k = k + 1) begin
            if (h_lanes[k]) line_merged[q_lane*64 + k*8 +: 8] = hwdata[k*8 +: 8];
        end
    end

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            h_st       <= H_RDY;
            hreadyout  <= 1'b1;
            hresp      <= 1'b0;
            hrdata     <= 64'd0;
            q_addr     <= 32'd0;
            q_write    <= 1'b0;
            q_size     <= 3'd0;
            q_wdata    <= 64'd0;
            req_t      <= 1'b0;
            ack_s      <= 2'b00;
            ack_seen   <= 1'b0;
            line_valid <= 1'b0;
            line_tag   <= {TW{1'b0}};
            line_data  <= {DW{1'b0}};
            st_rd_n    <= 32'd0;
            st_rd_cyc  <= 32'd0;
            st_wr_n    <= 32'd0;
            st_wr_cyc  <= 32'd0;
            st_hit     <= 32'd0;
        end else begin
            ack_s <= {ack_s[0], ack_t};
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
                    if (in_range && !q_write && line_hit) begin
                        hrdata    <= line_data[q_lane*64 +: 64];
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                        st_hit    <= st_hit + 32'd1;
                    end else if (in_range) begin
                        req_t <= ~req_t;
                        h_st  <= H_WAIT;
                        if (q_write) st_wr_n <= st_wr_n + 32'd1;
                        else         st_rd_n <= st_rd_n + 32'd1;
                        if (q_write && line_hit) line_data <= line_merged;
                    end else if (in_stat) begin
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
                        hrdata    <= c_rline[q_lane*64 +: 64];
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                        if (!q_write) begin
                            line_valid <= 1'b1;
                            line_tag   <= q_addr[MEM_AW-1:LINE_AW];
                            line_data  <= c_rline;
                        end
                    end
                end
                default: begin
                    hreadyout <= 1'b1;
                    h_st      <= H_RDY;
                end
            endcase
        end
    end

    // ---------------------------------------------------------
    // LiteDRAM 側 (cclk): 1 つの転送を、native ポートのコマンド 1 回にする
    // ---------------------------------------------------------
    localparam [1:0] C_IDLE  = 2'd0;
    localparam [1:0] C_WRITE = 2'd1;  // 書き込みコマンドとデータを出している (両方が受け付けられるまで)
    localparam [1:0] C_READ  = 2'd2;  // 読み出しコマンドを出している (受け付けられるまで)
    localparam [1:0] C_RDATA = 2'd3;  // 読み出しデータを待つ

    reg [1:0] c_st;
    reg [1:0] req_s;
    reg       req_seen;
    wire      req_new = (req_s[1] != req_seen);

    assign rdata_ready = (c_st == C_RDATA);

    // q_addr、q_write、q_size、q_wdata は、req を受けてから ack を返すまで hclk 側で変わらないので、cclk で読んでよい
    wire [(1<<LINE_AW)-1:0] w_we = {{((1<<LINE_AW)-8){1'b0}}, h_lanes} << (q_lane * 8);

    always @(posedge cclk or negedge crst_n) begin
        if (!crst_n) begin
            c_st        <= C_IDLE;
            req_s       <= 2'b00;
            req_seen    <= 1'b0;
            ack_t       <= 1'b0;
            c_rline     <= {DW{1'b0}};
            cmd_valid   <= 1'b0;
            cmd_we      <= 1'b0;
            cmd_addr    <= {TW{1'b0}};
            wdata_valid <= 1'b0;
            wdata_data  <= {DW{1'b0}};
            wdata_we    <= {(1<<LINE_AW){1'b0}};
            st_c_rwait  <= 32'd0;
            st_c_rlat   <= 32'd0;
            st_c_wwait  <= 32'd0;
        end else begin
            req_s <= {req_s[0], req_t};
            if (c_st == C_READ)  st_c_rwait <= st_c_rwait + 32'd1;
            if (c_st == C_RDATA) st_c_rlat  <= st_c_rlat + 32'd1;
            if (c_st == C_WRITE) st_c_wwait <= st_c_wwait + 32'd1;
            case (c_st)
                C_IDLE: begin
                    if (req_new) begin
                        req_seen  <= req_s[1];
                        cmd_addr  <= q_addr[MEM_AW-1:LINE_AW];
                        cmd_we    <= q_write;
                        cmd_valid <= 1'b1;
                        if (q_write) begin
                            wdata_data  <= {(DW/64){q_wdata}};
                            wdata_we    <= w_we;
                            wdata_valid <= 1'b1;
                            c_st        <= C_WRITE;
                        end else begin
                            c_st <= C_READ;
                        end
                    end
                end
                C_WRITE: begin
                    // コマンドとデータは別々に受け付けられる。両方が受け付けられたら完了
                    if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
                    if (wdata_valid && wdata_ready) wdata_valid <= 1'b0;
                    if ((!cmd_valid || cmd_ready) && (!wdata_valid || wdata_ready)) begin
                        ack_t <= ~ack_t;
                        c_st  <= C_IDLE;
                    end
                end
                C_READ: begin
                    if (cmd_ready) begin
                        cmd_valid <= 1'b0;
                        c_st      <= C_RDATA;
                    end
                end
                default: begin   // C_RDATA
                    if (rdata_valid) begin
                        c_rline <= rdata_data;
                        ack_t   <= ~ack_t;
                        c_st    <= C_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
