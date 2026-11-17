// =============================================================
// File:        rtl/apb_paddr_probe.v
// Module:      apb_paddr_probe
// Role:        APB_P* に届いた PADDR、PSTRB、PWDATA を、CPU のプログラムから読めるようにする回路。
//              本物の AE350 が APB_P* に出す PADDR の形 (0xF800_0000 からのフルアドレスか、下位ビットだけか) を、
//              実機で確かめるために置く。ファブリック側の回路で、実機でもそのまま使う。
//
// Registers (読み出しは PADDR[4:2] で選ぶ。0x10〜0x18 は 0x0〜0x8 と同じ。エラー応答は返さない):
//   書き込み (アドレスによらない)  そのときの PADDR、PSTRB、PWDATA を保持する
//   0x0  R   最後に書き込んだときの PADDR
//   0x4  R   最後に書き込んだときの PSTRB (下位 4 ビット)
//   0x8  R   最後に書き込んだときの PWDATA
//   0xC  R   この読み出し自体の PADDR
//   0x1C R   この読み出し自体の PADDR の下位 8 ビットを、4 つのバイトレーンすべてに並べる
//            (1 バイトと 2 バイトの読み出しで、PADDR の下位 2 ビットがそのまま届くかを調べる)
//
// Ports:
//   input  wire        clk / rst_n
//   input  wire        psel / penable / pwrite
//   input  wire [31:0] paddr / pwdata
//   input  wire [3:0]  pstrb
//   output wire [31:0] prdata
//   output wire        pready / pslverr
//
// Clock:       clk (APB_CLK と同じクロック)
// Reset:       rst_n (アクティブ Low、非同期)
// =============================================================

`default_nettype none

module apb_paddr_probe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr
);

    reg [31:0] last_paddr;
    reg [3:0]  last_pstrb;
    reg [31:0] last_pwdata;

    wire access = psel && penable;

    assign pready  = 1'b1;
    assign pslverr = 1'b0;
    assign prdata  = (paddr[3:2] == 2'd0) ? last_paddr :
                     (paddr[3:2] == 2'd1) ? {28'd0, last_pstrb} :
                     (paddr[3:2] == 2'd2) ? last_pwdata :
                     paddr[4]              ? {4{paddr[7:0]}} :
                                            paddr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_paddr  <= 32'd0;
            last_pstrb  <= 4'd0;
            last_pwdata <= 32'd0;
        end else if (access && pwrite) begin
            last_paddr  <= paddr;
            last_pstrb  <= pstrb;
            last_pwdata <= pwdata;
        end
    end

endmodule

`default_nettype wire
