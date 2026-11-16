// =============================================================
// File:        ae350/rtl/ahb_ddr3.v
// Module:      ahb_ddr3
// Role:        AE350 の DDR_H* (= 64 bit の AHB) を、Gowin の DDR3 Memory Interface の IP (= 利用者の側の口) につなぐ回路
//              (= 2026-11-13)。FPGA のロジック側の回路で、ボードの DDR3 の版 (= board/tang_console/build.sh の MEM=ddr3)
//              で使う。シミュレーションでは DDR_H* の先を SDRAM のまま使うので、この回路は使わない。
//
//   hclk (= DDR_CLK) の側                           cclk (= IP の利用者の側のクロック、clk_out) の側
//   AE350 の転送を受け、控えて、トグルで渡す ───▶  読み: 番地を含む 32 byte (= 1 回の命令の 256 bit) を読み、
//                                                       番地の bit 4〜3 で 8 byte を選ぶ
//                                                  書き: 256 bit のうち、HSIZE と番地で決まる byte だけを書く
//                                                       (= ほかの byte はマスクする。1 回の命令)
//   応答を受けて AE350 に返す              ◀───  終わったらトグルで返す
//
//   - IP の設定 (= board/tang_console/ddr3/ddr3_memory_interface.ipc) は DQ 32 bit、1:4。1 回の命令で 8 回の転送
//     (= 32 byte) をまとめて読み書きし、利用者の側では 256 bit を 1 サイクルで渡す
//   - IP に命令を出す順は、Sipeed の DDR3 の試験 (= TangMega-138K-example の ddrtest.v、実機で動いた) と同じ:
//     書きは cmd_ready と wr_data_rdy がそろったサイクルに、命令 (= 0)、番地、データ、マスク、wr_data_en / wr_data_end を
//     同時に出す。読みは cmd_ready のサイクルに命令 (= 1) と番地を出し、rd_data_valid で 256 bit を受ける。
//     cmd_en は受けられた (= cmd_ready が 1 の) サイクルまで出し続ける
//   - 番地: IP の番地は 4 byte 単位 (= 列が DQ 32 bit の 1 回の転送。ddrtest.v は 1 回の命令ごとに列を 8 進める)。
//     byte の番地の bit 29〜2 を IP の番地の bit 27〜0 にする (= 1 GB の全部。IP の番地の bit 28 はランクで、使わない)
//   - 書き込みのマスクは 1 の byte を書かない。256 bit の中の並びは、byte の番地の小さい方が下位 (= Gowin の
//     gw_ahb_ddr3.v と同じ)
//   - IP の初期化と調整 (= init_calib_complete) が済むまで、cclk の側は転送を受けない (= AE350 は待たされるだけ)
//   - リフレッシュは IP が自分で出す設定 (= USER_REFRESH が無効) なので、この回路では出さない
//   - AE350 に返す HREADYOUT / HRDATA / HRESP はレジスタの出力 (= ahb_sdram.v と同じ理由)。転送は 1 つずつ
//   - 直前に IP から読んだ 32 byte を覚えておき (= line_*)、同じ 32 byte の読みは IP に行かずに返す。同じ 32 byte への書きは、
//     覚えている値も書き換えてから IP に書く (= 2026-11-13)
//   - DDR3 の範囲 (= 1 GB) の外の番地には、IP に行かずにエラー応答 (= 2 サイクル) を返す。ただし STAT_BASE からの 32 byte は、
//     読み書きにかかった時間を数えるカウンタ (= 下の表。読むと値、書いても何もしない。2026-11-13、DDR3 の読みが SDRAM より遅い
//     件の内訳を見るため)。カウンタは消さない (= 読む側が前後の差を取る)。IP のクロックの側のカウンタは、転送の無い間は
//     変わらないので (= 転送は 1 つずつ、カウンタを読む転送は IP に行かない)、c_rdata と同じく DDR_CLK の側でそのまま読む
//
//     +0x00 読みの転送の数                          +0x04 読みで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x08 書きの転送の数                          +0x0C 書きで HREADYOUT = 0 だった DDR_CLK のサイクル数の合計
//     +0x10 読みの命令を出してから受けられるまでの      +0x14 読みの命令を受けられてから読んだ値が来るまでの
//           IP のクロックのサイクル数の合計                IP のクロックのサイクル数の合計
//     +0x18 書きの命令を出してから受けられるまでの      +0x1C 覚えている 32 byte から返した読みの数
//           IP のクロックのサイクル数の合計
//
// Ports:
//   input  wire hclk / hresetn            DDR_CLK と、AE350 が出す DDR_RSTN
//   AHB のスレーブ (= DDR_H*。hready は AE350 の DDR_HREADY と同じ、この回路の hreadyout)
//   input  wire cclk                      IP の clk_out (= 100 MHz)
//   input  wire calib_done                IP の init_calib_complete (= cclk に同期)。0 の間、cclk の側はリセットされたまま
//   IP の利用者の側の口 (= cmd_* / addr / wr_data_* / rd_data_*)
// =============================================================

`default_nettype none

module ahb_ddr3 #(
    parameter [31:0] STAT_BASE = 32'h7F00_0000
) (
    // DDR_CLK の側
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

    // IP の利用者の側
    input  wire         cclk,
    input  wire         calib_done,
    input  wire         cmd_ready,
    output reg  [2:0]   cmd,
    output reg          cmd_en,
    output wire [28:0]  addr,
    input  wire         wr_data_rdy,
    output reg  [255:0] wr_data,
    output reg          wr_data_en,
    output reg  [31:0]  wr_data_mask,
    input  wire [255:0] rd_data,
    input  wire         rd_data_valid
);

    // ---------------------------------------------------------
    // DDR_CLK の側: 受けて、控えて、渡す (= ahb_sdram.v と同じ形)
    // ---------------------------------------------------------
    localparam [1:0] H_RDY  = 2'd0;   // HREADYOUT = 1。アドレスフェーズを受けられる
    localparam [1:0] H_DATA = 2'd1;   // データフェーズの 1 サイクル目 (= 書く値を控える)
    localparam [1:0] H_WAIT = 2'd2;   // IP の側の応答を待つ
    localparam [1:0] H_ERR1 = 2'd3;   // エラー応答の 1 サイクル目

    reg [1:0]  h_st;
    reg [31:0] q_addr;
    reg        q_write;
    reg [2:0]  q_size;
    reg [63:0] q_wdata;
    reg        req_t;                 // 渡すたびに反転する
    reg [1:0]  ack_s;                 // cclk の側の ack_t を 2 段で受ける
    reg        ack_seen;              // 最後に受けた ack_t
    reg        ack_t;
    reg [63:0] c_rdata;               // cclk の側が読んだ値 (= 次の要求まで変わらないので、ack を受けてから hclk で読む)

    wire in_range = (q_addr[31:30] == 2'b00);
    wire ack_new  = (ack_s[1] != ack_seen);
    wire in_stat  = (q_addr[31:5] == STAT_BASE[31:5]);

    // カウンタ (= DDR_CLK の側と、IP のクロックの側)
    reg [31:0] st_rd_n, st_rd_cyc, st_wr_n, st_wr_cyc;
    reg [31:0] st_c_rwait, st_c_rlat, st_c_wwait;
    wire h_busy = !hreadyout && ((h_st == H_DATA && in_range) || h_st == H_WAIT);

    // 直前に IP から読んだ 32 byte (= 2026-11-13。DDR3 の IP は 1 回の命令で 32 byte を読むが、AE350 の転送は 1 回 4 byte なので、
    // 続けて読むと同じ 32 byte を何度も読み直していた)。同じ 32 byte の読みは IP に行かずに返し、書きは覚えている値も書き換える
    // (= DDR3 の中身と食い違わない。DDR_H* の先に行く道はこの回路だけ)
    reg         line_valid;
    reg [24:0]  line_tag;              // byte の番地の bit 29〜5
    reg [255:0] line_data;
    reg [255:0] c_rline;               // cclk の側が読んだ 32 byte (= c_rdata と同じく、ack を受けてから hclk で読む)
    reg [31:0]  st_hit;
    wire        line_hit = line_valid && (line_tag == q_addr[29:5]);

    function [63:0] stat_word(input [1:0] i);
        case (i)
            2'd0:    stat_word = {st_rd_cyc, st_rd_n};
            2'd1:    stat_word = {st_wr_cyc, st_wr_n};
            2'd2:    stat_word = {st_c_rlat, st_c_rwait};
            default: stat_word = {st_hit, st_c_wwait};
        endcase
    endfunction

    // HSIZE と番地の下位から、書く byte を決める (= 64 bit のバスの byte のレーン)
    function [7:0] lanes(input [2:0] a, input [2:0] size);
        case (size)
            3'd0:    lanes = 8'b0000_0001 << a;
            3'd1:    lanes = 8'b0000_0011 << {a[2:1], 1'b0};
            3'd2:    lanes = 8'b0000_1111 << {a[2], 2'b00};
            default: lanes = 8'b1111_1111;
        endcase
    endfunction

    // 覚えている 32 byte に、書く値を重ねたもの (= 書く byte だけ hwdata にする)
    wire [7:0] h_lanes = lanes(q_addr[2:0], q_size);
    reg [255:0] line_merged;
    integer     k;
    always @(*) begin
        line_merged = line_data;
        for (k = 0; k < 8; k = k + 1) begin
            if (h_lanes[k]) line_merged[{24'd0, q_addr[4:3], 6'd0} + k*8 +: 8] = hwdata[k*8 +: 8];
        end
    end

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
            st_rd_n   <= 32'd0;
            st_rd_cyc <= 32'd0;
            st_wr_n   <= 32'd0;
            st_wr_cyc <= 32'd0;
            st_hit    <= 32'd0;
            line_valid <= 1'b0;
            line_tag   <= 25'd0;
            line_data  <= 256'd0;
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
                        // 覚えている 32 byte から返す (= IP に行かない)
                        hrdata    <= line_data[{q_addr[4:3], 6'd0} +: 64];
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                        st_hit    <= st_hit + 32'd1;
                    end else if (in_range) begin
                        req_t <= ~req_t;
                        h_st  <= H_WAIT;
                        if (q_write) st_wr_n <= st_wr_n + 32'd1;
                        else         st_rd_n <= st_rd_n + 32'd1;
                        if (q_write && line_hit) line_data <= line_merged;   // 覚えている値も書き換える
                    end else if (in_stat) begin
                        // カウンタ: 読むと値、書いても何もしない (= どちらも OKAY)
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
                        hrdata    <= c_rdata;
                        hreadyout <= 1'b1;
                        h_st      <= H_RDY;
                        if (!q_write) begin
                            // 読んだ 32 byte を覚える
                            line_valid <= 1'b1;
                            line_tag   <= q_addr[29:5];
                            line_data  <= c_rline;
                        end
                    end
                end
                default: begin
                    // エラー応答の 2 サイクル目 (= HRESP = 1 のまま HREADYOUT = 1)
                    hreadyout <= 1'b1;
                    h_st      <= H_RDY;
                end
            endcase
        end
    end

    // ---------------------------------------------------------
    // IP の側 (= cclk): 1 つの転送を、IP の命令 1 回にする
    // ---------------------------------------------------------
    localparam [1:0] C_IDLE  = 2'd0;
    localparam [1:0] C_WRITE = 2'd1;  // 書きの命令を出している (= 受けられるまで)
    localparam [1:0] C_READ  = 2'd2;  // 読みの命令を出している (= 受けられるまで)
    localparam [1:0] C_RDATA = 2'd3;  // 読んだ値を待つ

    reg [1:0]  c_st;
    reg [1:0]  req_s;                 // hclk の側の req_t を 2 段で受ける
    reg        req_seen;
    reg [27:0] c_word;                // IP の番地 (= byte の番地の bit 29〜2。下位 3 bit は 0)
    reg [1:0]  c_lane;                // 32 byte のうちの 8 byte の位置 (= byte の番地の bit 4〜3)

    wire req_new = (req_s[1] != req_seen);

    assign addr = {1'b0, c_word};

    // q_addr / q_write / q_size / q_wdata は、req を受けてから ack を返すまで hclk の側で変わらないので、cclk で読む
    wire [31:0] w_mask  = ~({24'd0, h_lanes} << {q_addr[4:3], 3'b000});

    always @(posedge cclk or negedge calib_done) begin
        if (!calib_done) begin
            c_st         <= C_IDLE;
            req_s        <= 2'b00;
            req_seen     <= 1'b0;
            ack_t        <= 1'b0;
            c_word       <= 28'd0;
            c_lane       <= 2'd0;
            c_rdata      <= 64'd0;
            c_rline      <= 256'd0;
            cmd          <= 3'b000;
            cmd_en       <= 1'b0;
            wr_data      <= 256'd0;
            wr_data_en   <= 1'b0;
            wr_data_mask <= 32'hFFFF_FFFF;
            st_c_rwait   <= 32'd0;
            st_c_rlat    <= 32'd0;
            st_c_wwait   <= 32'd0;
        end else begin
            req_s <= {req_s[0], req_t};
            if (c_st == C_READ)  st_c_rwait <= st_c_rwait + 32'd1;
            if (c_st == C_RDATA) st_c_rlat  <= st_c_rlat + 32'd1;
            if (c_st == C_WRITE) st_c_wwait <= st_c_wwait + 32'd1;
            case (c_st)
                C_IDLE: begin
                    if (req_new) begin
                        req_seen <= req_s[1];
                        c_word   <= {q_addr[29:5], 3'b000};
                        c_lane   <= q_addr[4:3];
                        if (q_write) begin
                            cmd          <= 3'b000;
                            cmd_en       <= 1'b1;
                            wr_data      <= {4{q_wdata}};
                            wr_data_mask <= w_mask;
                            wr_data_en   <= 1'b1;
                            c_st         <= C_WRITE;
                        end else begin
                            cmd    <= 3'b001;
                            cmd_en <= 1'b1;
                            c_st   <= C_READ;
                        end
                    end
                end
                C_WRITE: begin
                    // 命令とデータは、cmd_ready と wr_data_rdy がそろったサイクルに受けられる
                    if (cmd_ready && wr_data_rdy) begin
                        cmd_en     <= 1'b0;
                        wr_data_en <= 1'b0;
                        ack_t      <= ~ack_t;
                        c_st       <= C_IDLE;
                    end
                end
                C_READ: begin
                    if (cmd_ready) begin
                        cmd_en <= 1'b0;
                        c_st   <= C_RDATA;
                    end
                end
                default: begin   // C_RDATA
                    if (rd_data_valid) begin
                        c_rdata <= rd_data[c_lane*64 +: 64];
                        c_rline <= rd_data;
                        ack_t   <= ~ack_t;
                        c_st    <= C_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
