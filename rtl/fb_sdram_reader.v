// =============================================================
// File:        rtl/fb_sdram_reader.v
// Module:      fb_sdram_reader
// Role:        表示の回路 (rtl/fb_display.v) の、SDRAM の版の読み出しの回路。fb_display のつなぎ目 (mreq、lb_*、mdone) を、
//              sdram_ctrl_hs の表示用の読み出しのポート (dr_*) につなぐ。クロックは sdram_ctrl_hs と同じ s_clk。
//
//   - mreq で dr_start を出す (dr_addr は mreq_addr の 16 バイト単位、dr_bursts は 1 ラインの LINE_BYTES / 16)
//   - dr_wvalid ごとに、ラインの中のワードの番号を 1 つ進めて lb_we を出す。dr_done で mdone を出す (最後の lb_we と同じクロック)
//   - fb_display は前の要求の mdone を受けるまで次の mreq を出さないので、dr_busy の間に dr_start を出すことはない
//
// Parameters:
//   AW          バイトアドレスの幅
//   LINE_BYTES  1 ラインのバイト数 (16 の倍数)
// =============================================================

`default_nettype none

module fb_sdram_reader #(
    parameter integer AW         = 25,
    parameter integer LINE_BYTES = 2560
) (
    input  wire          clk,
    input  wire          rst_n,
    // fb_display へ
    input  wire          mreq,
    input  wire [AW-1:0] mreq_addr,
    output reg           lb_we,
    output reg  [10:0]   lb_waddr,
    output reg  [15:0]   lb_wdata,
    output reg           mdone,
    // sdram_ctrl_hs の表示用の読み出しのポートへ
    output reg           dr_start,
    output reg  [AW-5:0] dr_addr,
    output wire [AW-5:0] dr_bursts,
    input  wire          dr_busy,
    input  wire          dr_wvalid,
    input  wire [15:0]   dr_wdata,
    input  wire          dr_done
);
    localparam integer BURSTS = LINE_BYTES / 16;
    assign dr_bursts = BURSTS[AW-5:0];

    reg [10:0] idx;      // 次に返るワードの番号

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_start <= 1'b0;
            dr_addr  <= {(AW-4){1'b0}};
            idx      <= 11'd0;
            lb_we    <= 1'b0;
            lb_waddr <= 11'd0;
            lb_wdata <= 16'd0;
            mdone    <= 1'b0;
        end else begin
            dr_start <= mreq;
            if (mreq) begin
                dr_addr <= mreq_addr[AW-1:4];
                idx     <= 11'd0;
            end
            lb_we    <= dr_wvalid;
            lb_waddr <= idx;
            lb_wdata <= dr_wdata;
            if (dr_wvalid) idx <= idx + 11'd1;
            mdone    <= dr_done;
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, dr_busy, mreq_addr[3:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
