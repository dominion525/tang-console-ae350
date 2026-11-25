// =============================================================
// File:        rtl/fb_display.v
// Module:      fb_display
// Role:        メモリに置いたフレームバッファ (RGB565) を、HDMI の出力回路 (rtl/vendor/hdmi/hdmi.sv) に渡す表示の回路。
//              メモリの種類は知らない。メモリの側の読み出しの回路 (SDRAM の版は rtl/fb_sdram_reader.v) とは、下の
//              「つなぎ目」の約束だけでつなぐ。CTRL の ENABLE が 0 のフレームと、読み込みが間に合わなかったラインは、
//              カラーバー (rtl/hdmi_test_pattern.v) を出す。
//
//   つなぎ目 (メモリのクロック mclk 側)
//     fb_display → 読み出しの回路  mreq (1 クロックのパルス) と mreq_addr (ラインの先頭のバイトアドレス)。STRIDE バイトを読む
//     読み出しの回路 → fb_display  lb_we、lb_waddr (ラインの中のワードの番号)、lb_wdata (16 ビット = 1 画素) を、読めた順に。
//                                  1 ラインを書き終えたら mdone (1 クロックのパルス。最後の lb_we と同じクロックでよい)
//     同時に出す要求は 1 つまで。ラインバッファのどちら側に書くかは、この回路が覚えておく
//
//   読み込みと表示 (画素クロック vclk 側。cx、cy は hdmi.sv の座標で、表示期間は cx < H_ACTIVE、cy < V_ACTIVE)
//     - ライン y の始まり (cx = 1) で、ライン y + 1 を要求したいことを覚え (ライン 0 は、最後のライン cy = V_TOTAL - 1 で)、
//       前の要求が終わっていれば、次のクロックから出す。終わっていなければ、終わった時点で出す (1 ラインが遅れても、次の
//       ラインは間に合うように)。ENABLE が 0 のフレームでは要求しない
//     - ライン y の 1 つ前の画素 (前のラインの cx = H_TOTAL - 1) で、ライン y の読み込みが終わっているかを見る。
//       終わっていればラインバッファの値を、終わっていなければカラーバーを出し、UNDERRUN を 1 にする
//     - hdmi.sv は cx の画素の色を次のクロックで受け取る。ラインバッファを 1 つ先の座標で読み (ブロック RAM の 1 クロック)、
//       次のクロックで色を変換したレジスタを出す。カラーバーも同じクロックで hdmi_test_pattern が出す
//     - 色は RGB565 の各色の上位のビットを下位に繰り返して RGB888 にする
//     - CTRL と FB_BASE は、最後のライン (cy = V_TOTAL - 1) の cx = 0 で取り込む (フレームの途中で書いても、次のフレームから)
//
//   制御レジスタ (APB。PADDR[3:2] で選び、上位のビットは見ない。PREADY は常に 1、PSLVERR は常に 0)
//     +0x00 CTRL     R/W  bit 0 ENABLE (0 はカラーバー、1 はフレームバッファ)。リセット後 0
//     +0x04 FB_BASE  R/W  フレームバッファの先頭のバイトアドレス (下位 4 ビットは 0 に固定)。リセット後 FB_BASE_INIT
//     +0x08 FRAME    R    表示したフレームの数 (垂直帰線の始まり、cy = V_ACTIVE の cx = 0 で 1 増える)。書き込みは無視
//     +0x0C STATUS   R/W  bit 0 UNDERRUN (読み込みが間に合わなかったラインがあった)。1 を書くと 0 に戻る
//
//   クロックの乗せ換え (すべて、値を先に決めてからトグルを変え、受け側でトグルを 2 段で受ける)
//     APB → vclk    CTRL か FB_BASE を書くたびに cfg_tgl を変える。vclk 側は変化を見たら値を写す
//     vclk → APB    フレームの数え上げ (frame_tgl) と、UNDERRUN の発生 (urun_tgl)
//     vclk → mclk   要求 (req_tgl。アドレスとラインバッファの側は先に決める)
//     mclk → vclk   完了 (done_tgl)
//
// Parameters:
//   H_TOTAL / V_ACTIVE / V_TOTAL  フレームの大きさと表示期間のライン数 (既定値は 1280×720 / 60 Hz、VIC 4)。表示期間の横の
//                 画素数はパラメータにしない (cx が表示期間の外の色は hdmi.sv が使わない。1 ラインの画素数は STRIDE / 2 で、2048 以下)
//   STRIDE        行の間隔 (バイト。16 の倍数)
//   AW            メモリのバイトアドレスの幅
//   FB_BASE_INIT  FB_BASE のリセット後の値
// =============================================================

`default_nettype none

module fb_display #(
    parameter integer   H_TOTAL      = 1650,
    parameter integer   V_ACTIVE     = 720,
    parameter integer   V_TOTAL      = 750,
    parameter integer   STRIDE       = 2560,
    parameter integer   AW           = 25,
    parameter [AW-1:0]  FB_BASE_INIT = 25'h1C0_0000
) (
    // APB (制御レジスタ)
    input  wire          pclk,
    input  wire          presetn,
    input  wire          psel,
    input  wire          penable,
    input  wire          pwrite,
    input  wire [31:0]   paddr,
    input  wire [31:0]   pwdata,
    input  wire [3:0]    pstrb,
    output wire [31:0]   prdata,
    output wire          pready,
    output wire          pslverr,

    // 画素クロック (hdmi.sv)
    input  wire          vclk,
    input  wire          vrst_n,
    input  wire [10:0]   cx,
    input  wire [9:0]    cy,
    output wire [23:0]   rgb,

    // メモリのクロック (読み出しの回路)
    input  wire          mclk,
    input  wire          mrst_n,
    output reg           mreq,
    output reg  [AW-1:0] mreq_addr,
    input  wire          lb_we,
    input  wire [10:0]   lb_waddr,
    input  wire [15:0]   lb_wdata,
    input  wire          mdone
);
    // ---------------------------------------------------------
    // APB 側
    // ---------------------------------------------------------
    reg          ctrl_en;
    reg [AW-1:4] fb_base;
    reg [31:0]   frame_cnt;
    reg          underrun;
    reg          cfg_tgl;
    reg [2:0]    frame_s, urun_s;     // vclk からのトグルを受ける (2 段 + 前の値)
    wire         frame_tgl, urun_tgl;

    wire        access = psel && penable;
    wire [31:0] base32 = {{(32-AW){1'b0}}, fb_base, 4'b0000};
    function [31:0] merge(input [31:0] old, input [31:0] wd, input [3:0] st);
        merge = {st[3] ? wd[31:24] : old[31:24], st[2] ? wd[23:16] : old[23:16],
                 st[1] ? wd[15:8]  : old[15:8],  st[0] ? wd[7:0]   : old[7:0]};
    endfunction
    wire [31:0] base_new = merge(base32, pwdata, pstrb);

    assign pready  = 1'b1;
    assign pslverr = 1'b0;
    assign prdata  = (paddr[3:2] == 2'd0) ? {31'd0, ctrl_en} :
                     (paddr[3:2] == 2'd1) ? base32 :
                     (paddr[3:2] == 2'd2) ? frame_cnt : {31'd0, underrun};

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl_en   <= 1'b0;
            fb_base   <= FB_BASE_INIT[AW-1:4];
            frame_cnt <= 32'd0;
            underrun  <= 1'b0;
            cfg_tgl   <= 1'b0;
            frame_s   <= 3'b000;
            urun_s    <= 3'b000;
        end else begin
            frame_s <= {frame_s[1:0], frame_tgl};
            urun_s  <= {urun_s[1:0], urun_tgl};
            if (frame_s[2] != frame_s[1]) frame_cnt <= frame_cnt + 32'd1;
            if (access && pwrite) begin
                case (paddr[3:2])
                    2'd0: if (pstrb[0]) begin ctrl_en <= pwdata[0]; cfg_tgl <= ~cfg_tgl; end
                    2'd1: begin fb_base <= base_new[AW-1:4]; cfg_tgl <= ~cfg_tgl; end
                    2'd3: if (pstrb[0] && pwdata[0]) underrun <= 1'b0;
                    default: ;
                endcase
            end
            if (urun_s[2] != urun_s[1]) underrun <= 1'b1;   // 0 に戻す書き込みと同時なら、発生を優先する
        end
    end

    // ---------------------------------------------------------
    // 画素クロック側
    // ---------------------------------------------------------
    localparam integer  H_LAST_I = H_TOTAL - 1;
    localparam integer  V_LAST_I = V_TOTAL - 1;
    localparam [10:0]   H_LAST   = H_LAST_I[10:0];
    localparam [9:0]    V_LAST   = V_LAST_I[9:0];
    localparam [9:0]    V_ACT    = V_ACTIVE[9:0];
    localparam [AW-1:0] STRIDE_A = STRIDE[AW-1:0];

    // APB からの設定 (写し → フレームの始まりで取り込む)
    reg [2:0]    cfg_s;
    reg          en_p, en_a;
    reg [AW-1:4] base_p;
    reg [AW-1:0] next_addr;          // 次に要求するラインの先頭のアドレス
    // 要求と完了
    reg          req_tgl_v;          // vclk 側で変える要求のトグル
    reg          req_side;           // 要求したラインの、ラインバッファの側
    reg          req_live;           // 要求したラインを、まだ待っている (同じ側の次のラインを待ち始めたら 0。その完了は捨てる)
    reg          want;               // 出したい要求がある (前の要求が終わったら出す)
    reg          want_side;
    reg [AW-1:0] want_addr;
    reg [AW-1:0] req_addr;
    reg [2:0]    done_s;
    reg [1:0]    ready;              // ラインバッファの側ごとに、読み込みが終わっている
    reg          frame_tgl_v, urun_tgl_v;
    // 表示
    reg          show;               // いまのラインは、ラインバッファの値を出す
    reg [15:0]   lb_q;
    reg [23:0]   rgb_fb;
    reg          show_q;
    wire [23:0]  bar_rgb;

    assign frame_tgl = frame_tgl_v;
    assign urun_tgl  = urun_tgl_v;

    // 次の画素の座標 (ラインバッファを 1 つ先で読む)
    wire        h_end = (cx == H_LAST);
    wire [10:0] nx    = h_end ? 11'd0 : cx + 11'd1;
    wire [9:0]  ny    = h_end ? ((cy == V_LAST) ? 10'd0 : cy + 10'd1) : cy;
    // 次のライン (要求するライン)
    wire [9:0]  y_next = (cy == V_LAST) ? 10'd0 : cy + 10'd1;
    wire        outstanding = (req_tgl_v != done_s[1]);

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            cfg_s       <= 3'b000;
            en_p        <= 1'b0;
            en_a        <= 1'b0;
            base_p      <= FB_BASE_INIT[AW-1:4];
            next_addr   <= {AW{1'b0}};
            req_tgl_v   <= 1'b0;
            req_side    <= 1'b0;
            req_live    <= 1'b0;
            want        <= 1'b0;
            want_side   <= 1'b0;
            want_addr   <= {AW{1'b0}};
            req_addr    <= {AW{1'b0}};
            done_s      <= 3'b000;
            ready       <= 2'b00;
            frame_tgl_v <= 1'b0;
            urun_tgl_v  <= 1'b0;
            show        <= 1'b0;
        end else begin
            cfg_s  <= {cfg_s[1:0], cfg_tgl};
            done_s <= {done_s[1:0], done_tgl};
            // APB の値は、トグルが変わった後 (値は止まっている) に写す
            if (cfg_s[2] != cfg_s[1]) begin
                en_p   <= ctrl_en;
                base_p <= fb_base;
            end
            // 完了: 要求した側の読み込みが終わった
            if (done_s[2] != done_s[1] && req_live) ready[req_side] <= 1'b1;
            // フレームの始まり: 設定を取り込み、ライン 0 のアドレスに戻す
            if (cy == V_LAST && cx == 11'd0) begin
                en_a      <= en_p;
                next_addr <= {base_p, 4'b0000};
                want      <= 1'b0;
            end
            // 垂直帰線の始まりで、フレームを数える
            if (cy == V_ACT && cx == 11'd0) frame_tgl_v <= ~frame_tgl_v;
            // ラインの始まりの次 (cx = 1) で、次のラインを要求したいことを覚える。前の要求が同じ側のラインなら (2 ライン以上
            // 遅れている)、その完了は捨てる。出したい要求は、前の要求が終わっていれば出す
            if (cx == 11'd1 && en_a && y_next < V_ACT) begin
                ready[y_next[0]] <= 1'b0;
                next_addr        <= next_addr + STRIDE_A;
                want             <= 1'b1;
                want_side        <= y_next[0];
                want_addr        <= next_addr;
                if (outstanding && req_side == y_next[0]) req_live <= 1'b0;
            end else if (want && !outstanding) begin
                want      <= 1'b0;
                req_live  <= 1'b1;
                req_side  <= want_side;
                req_addr  <= want_addr;
                req_tgl_v <= ~req_tgl_v;
            end
            // 次のラインの 1 つ前の画素で、そのラインに何を出すかを決める
            if (h_end) begin
                show <= en_a && (ny < V_ACT) && ready[ny[0]];
                if (en_a && (ny < V_ACT) && !ready[ny[0]]) urun_tgl_v <= ~urun_tgl_v;
            end
        end
    end

    // ラインバッファ (2 ライン。書き込みは mclk、読み出しは vclk のブロック RAM)
    reg [15:0] lb [0:4095];
    reg        m_side;
    always @(posedge mclk) begin
        if (lb_we) lb[{m_side, lb_waddr}] <= lb_wdata;
    end
    always @(posedge vclk) begin
        lb_q <= lb[{ny[0], nx}];
    end

    // 色の変換 (RGB565 → RGB888) と出力
    always @(posedge vclk) begin
        rgb_fb <= {lb_q[15:11], lb_q[15:13], lb_q[10:5], lb_q[10:9], lb_q[4:0], lb_q[4:2]};
        show_q <= show;
    end
    hdmi_test_pattern u_bar (.clk (vclk), .cx (cx), .rgb (bar_rgb));
    assign rgb = show_q ? rgb_fb : bar_rgb;

    // ---------------------------------------------------------
    // メモリのクロック側
    // ---------------------------------------------------------
    reg [2:0] req_s;
    reg       done_tgl;
    always @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            req_s     <= 3'b000;
            mreq      <= 1'b0;
            mreq_addr <= {AW{1'b0}};
            m_side    <= 1'b0;
            done_tgl  <= 1'b0;
        end else begin
            req_s <= {req_s[1:0], req_tgl_v};
            mreq  <= (req_s[2] != req_s[1]);
            if (req_s[2] != req_s[1]) begin
                mreq_addr <= req_addr;       // 要求のトグルより前に決まっていて、止まっている
                m_side    <= req_side;
            end
            if (mdone) done_tgl <= ~done_tgl;
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, paddr[31:4], paddr[1:0], base_new[31:AW], base_new[3:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
