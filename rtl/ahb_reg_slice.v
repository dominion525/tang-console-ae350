// =============================================================
// File:        ae350/rtl/ahb_reg_slice.v
// Module:      ahb_reg_slice
// Role:        AHB (= 32 bit) の転送をレジスタで区切る回路 (= 2026-11-10)。AE350 の EXTS_H* と FPGA 側のスレーブの
//              間に置く。実機では AE350 が FPGA の端にあり、行きと帰りの配線だけで AHB_CLK の周期の大半を使う。
//              マスタ側とも、スレーブ側とも、行きと帰りをレジスタで区切る (= どちらの境目も「レジスタから
//              レジスタへの片道」にする)。実機の配置配線で、次の 2 つの往復が AHB_CLK に収まらなかった。
//                - スレーブの HREADYOUT から AE350 を通って HSEL が戻り、スレーブのレジスタに入る
//                - (スライスを AE350 の近くに置いたとき) スレーブの HREADYOUT がスライスを通ってスレーブに戻る
//
//   マスタ側 (= AE350)                        スレーブ側
//   アドレスフェーズ (HREADYOUT = 1) ─控える─▶  ST_ADDR   アドレスフェーズを 1 つ出す (= HSEL / HTRANS はレジスタ)
//   データフェーズ (HREADYOUT = 0 で待たせる)    ST_DATA0  スレーブのデータフェーズの 1 サイクル目 (= 控えた応答はまだ前のもの)
//                                              ST_DATA   控えた HREADYOUT を待ち、応答を控える
//                                 ◀── 応答    ST_RDY    HREADYOUT = 1 (= 次の転送のアドレスフェーズを受けられる)
//   エラー応答は、マスタ側でも 2 サイクル (= HRESP = 1 で HREADYOUT = 0、続いて 1) にする
//
//   - 転送ごとに、マスタから見た待ちが 4 サイクル以上増える。転送の中身と順番は変わらない
//   - HWDATA はマスタのデータフェーズの値を、そのままスレーブのデータフェーズに渡す (= マスタは応答まで保つ)
//   - スレーブは 1 つだけで、転送は 1 つずつ出す (= アドレスフェーズを出すとき、スレーブは前の転送を終えている)
//
// Ports:
//   input  wire        clk / rst_n
//   m_*    マスタ (= AE350 の EXTS_H*) とつなぐ。m_hreadyout は AE350 の EXTS_HREADYIN へ
//   s_*    スレーブとつなぐ (= スレーブの HREADY には、スレーブの HREADYOUT をそのまま返す)
//
// Clock:       clk (= AHB_CLK)
// Reset:       rst_n (active low、非同期)
// =============================================================

`default_nettype none

module ahb_reg_slice (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        m_hsel,
    input  wire [31:0] m_haddr,
    input  wire [1:0]  m_htrans,
    input  wire        m_hwrite,
    input  wire [2:0]  m_hsize,
    input  wire [31:0] m_hwdata,
    output reg  [31:0] m_hrdata,
    output reg         m_hreadyout,
    output reg         m_hresp,

    output reg         s_hsel,
    output reg  [31:0] s_haddr,
    output wire [1:0]  s_htrans,
    output reg         s_hwrite,
    output reg  [2:0]  s_hsize,
    output wire [31:0] s_hwdata,
    input  wire [31:0] s_hrdata,
    input  wire        s_hreadyout,
    input  wire        s_hresp
);

    localparam [2:0] ST_RDY   = 3'd0;   // HREADYOUT = 1。アドレスフェーズを受けられる
    localparam [2:0] ST_ADDR  = 3'd1;   // スレーブにアドレスフェーズを出している
    localparam [2:0] ST_DATA0 = 3'd2;   // スレーブのデータフェーズの 1 サイクル目
    localparam [2:0] ST_DATA  = 3'd3;   // 控えたスレーブの応答を待つ
    localparam [2:0] ST_ERR1  = 3'd4;   // マスタ側のエラー応答の 1 サイクル目

    reg [2:0] st;

    // スレーブの応答を 1 段レジスタで受ける
    reg        r_ready;
    reg        r_resp;
    reg [31:0] r_rdata;

    assign s_htrans = s_hsel ? 2'b10 : 2'b00;   // NONSEQ / IDLE
    assign s_hwdata = m_hwdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= ST_RDY;
            m_hreadyout <= 1'b1;
            m_hresp     <= 1'b0;
            m_hrdata    <= 32'd0;
            s_hsel      <= 1'b0;
            s_haddr     <= 32'd0;
            s_hwrite    <= 1'b0;
            s_hsize     <= 3'd0;
            r_ready     <= 1'b1;
            r_resp      <= 1'b0;
            r_rdata     <= 32'd0;
        end else begin
            r_ready <= s_hreadyout;
            r_resp  <= s_hresp;
            r_rdata <= s_hrdata;

            case (st)
                ST_RDY: begin
                    // HREADYOUT = 1 の端 (= 前の転送のデータフェーズの終わり) で、次のアドレスフェーズを受ける
                    s_haddr  <= m_haddr;
                    s_hwrite <= m_hwrite;
                    s_hsize  <= m_hsize;
                    m_hresp  <= 1'b0;
                    if (m_hsel && m_htrans[1]) begin
                        m_hreadyout <= 1'b0;
                        s_hsel      <= 1'b1;
                        st          <= ST_ADDR;
                    end
                end
                ST_ADDR: begin
                    // スレーブはこの端でアドレスフェーズを受ける (= スレーブは前の転送を終えていて HREADYOUT = 1)
                    s_hsel <= 1'b0;
                    st     <= ST_DATA0;
                end
                ST_DATA0: begin
                    st <= ST_DATA;
                end
                ST_DATA: begin
                    // r_* はスレーブのデータフェーズの 1 サイクル前の応答。HREADYOUT = 1 ならそこで終わっている
                    if (r_ready) begin
                        m_hrdata <= r_rdata;
                        if (r_resp) begin
                            m_hresp <= 1'b1;
                            st      <= ST_ERR1;
                        end else begin
                            m_hreadyout <= 1'b1;
                            st          <= ST_RDY;
                        end
                    end
                end
                default: begin
                    // エラー応答の 2 サイクル目 (= HRESP = 1 のまま HREADYOUT = 1)
                    m_hreadyout <= 1'b1;
                    st          <= ST_RDY;
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = m_htrans[0];   // NONSEQ と SEQ を区別しない (= どちらも 1 つの転送として受ける)
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
