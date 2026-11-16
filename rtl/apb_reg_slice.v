// =============================================================
// File:        ae350/rtl/apb_reg_slice.v
// Module:      apb_reg_slice
// Role:        APB の転送をレジスタで区切る回路 (= 2026-11-10)。AE350 の APB_P* と FPGA 側の周辺回路の間に置く。
//              実機では AE350 が FPGA の端にあり、行きと帰りの配線だけで APB_CLK の周期の大半を使う。
//              PADDR からデコーダを通って PRDATA / PREADY / PSLVERR が AE350 に戻る経路を切り、AE350 に出入りする
//              経路をすべてレジスタからレジスタにする (= 配置配線の報告で違反していた経路)。
//
//   マスタ側 (= AE350)        スレーブ側 (= デコーダと周辺回路)
//   セットアップ  ─控える─▶  S_SETUP  (PSEL = 1、PENABLE = 0)
//   アクセス (待ち)           S_ACCESS (PSEL = 1、PENABLE = 1)、PREADY を待って応答を控える
//   アクセス (PREADY = 1) ◀─  S_DONE   控えた応答を出す
//
//   - 転送ごとに、マスタから見た待ちが 2 サイクル以上増える。転送の中身と順番は変わらない
//   - マスタ側の PREADY / PRDATA / PSLVERR はレジスタの出力
//
// Ports:
//   input  wire        clk / rst_n
//   m_*    マスタ (= AE350 の APB_P*) とつなぐ
//   s_*    スレーブ (= デコーダ) とつなぐ
//
// Clock:       clk (= APB_CLK)
// Reset:       rst_n (active low、非同期)
// =============================================================

`default_nettype none

module apb_reg_slice (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        m_psel,
    input  wire        m_penable,
    input  wire        m_pwrite,
    input  wire [31:0] m_paddr,
    input  wire [31:0] m_pwdata,
    input  wire [3:0]  m_pstrb,
    output reg  [31:0] m_prdata,
    output wire        m_pready,
    output reg         m_pslverr,

    output wire        s_psel,
    output wire        s_penable,
    output reg         s_pwrite,
    output reg  [31:0] s_paddr,
    output reg  [31:0] s_pwdata,
    output reg  [3:0]  s_pstrb,
    input  wire [31:0] s_prdata,
    input  wire        s_pready,
    input  wire        s_pslverr
);

    localparam [1:0] S_IDLE   = 2'd0;
    localparam [1:0] S_SETUP  = 2'd1;
    localparam [1:0] S_ACCESS = 2'd2;
    localparam [1:0] S_DONE   = 2'd3;

    reg [1:0] state;

    assign s_psel    = (state == S_SETUP) || (state == S_ACCESS);
    assign s_penable = (state == S_ACCESS);
    assign m_pready  = (state == S_DONE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            s_pwrite  <= 1'b0;
            s_paddr   <= 32'd0;
            s_pwdata  <= 32'd0;
            s_pstrb   <= 4'd0;
            m_prdata  <= 32'd0;
            m_pslverr <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    // 毎サイクル控え、マスタのセットアップのサイクル (= PSEL = 1、PENABLE = 0) で先へ進む
                    // (= PSEL を控えるレジスタの CE に配らない。実機で PSEL からの配線が APB_CLK に収まらなかった)
                    s_pwrite <= m_pwrite;
                    s_paddr  <= m_paddr;
                    s_pwdata <= m_pwdata;
                    s_pstrb  <= m_pstrb;
                    if (m_psel && !m_penable) state <= S_SETUP;
                end
                S_SETUP: begin
                    state <= S_ACCESS;
                end
                S_ACCESS: begin
                    if (s_pready) begin
                        m_prdata  <= s_prdata;
                        m_pslverr <= s_pslverr;
                        state     <= S_DONE;
                    end
                end
                default: begin
                    // マスタはこのサイクルで PREADY = 1 を見て転送を終える
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
