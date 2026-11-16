// =============================================================
// File:        rtl/ae350_plmt.v
// Module:      ae350_plmt
// Role:        AE350 の Hazard3 の版の中の PLMT (= Platform Level Machine Timer、段 4、2026-11-10)。
//              シミュレーション専用。レジスタの配置は MUG1029 表 15-1 に合わせる (= hart 0 だけ)。
//
// Registers (= Hazard3 の版が 0xE600_0000 からのオフセットで渡す):
//   0x00  MTIME[31:0]       0x04  MTIME[63:32]       R/W   clk の 1 サイクルごとに 1 進む。初期値 0
//   0x08  MTIMECMP0[31:0]   0x0C  MTIMECMP0[63:32]   R/W   初期値 0xFFFF_FFFF_FFFF_FFFF
//   それ以外                                            読むと 0、書いても何も起きない
//
// mtime のクロック (= 2026-11-10 に確かめた): Gowin の BSP (ae350.h の OSCFREQ = HCLKFREQ = 100 MHz) と
// PLMT のデモ (demo_plmt.c の MACHINE_TIMER_PERIOD = 2 * OSCFREQ が 2 秒) は、mtime がバスのクロック
// (= リファレンスデザインの AHB_CLK / APB_CLK、100 MHz) で進む前提。同じデザインの RTC_CLK は 10 MHz なので、
// RTC_CLK では進まない。Hazard3 の版は AHB_CLK (= clk) で 1 サイクルごとに進める
//
// Ports:
//   input  wire        clk / rst_n     AHB_CLK と、Hazard3 の版のリセット。mtime もこのクロックで進む
//   input  wire        wen             このサイクルに書く
//   input  wire [5:0]  addr            バイトのオフセット (= 下位 2 bit は見ない)
//   input  wire [31:0] wdata
//   input  wire [3:0]  wstrb           書くバイトレーン
//   output reg  [31:0] rdata           addr のレジスタの値 (= 組み合わせ回路)
//   output wire        mtip            mtime >= mtimecmp0 (= レベル)
//
// Design Notes:
//   - mtime を書いたサイクルは、書いた側の 32 bit は書いた値になり、進まない
//   - 64 bit のレジスタは 32 bit ずつ読み書きする。上位と下位を続けて読む間に繰り上がると値が割れるので、
//     ソフトウェアは「上位、下位、上位」と読んで上位が同じことを確かめる (= RISC-V の標準のやり方)
// =============================================================

`default_nettype none

module ae350_plmt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wen,
    input  wire [5:0]  addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output reg  [31:0] rdata,
    output wire        mtip
);

    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    // バイトレーンを選んで書いた値
    function [31:0] merge(input [31:0] old, input [31:0] new_value, input [3:0] strb);
        integer b;
        begin
            merge = old;
            for (b = 0; b < 4; b = b + 1) begin
                if (strb[b]) merge[b*8 +: 8] = new_value[b*8 +: 8];
            end
        end
    endfunction

    wire [3:0] word = addr[5:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
        end else begin
            mtime <= mtime + 64'd1;
            if (wen) begin
                case (word)
                    4'd0: mtime[31:0]     <= merge(mtime[31:0],     wdata, wstrb);
                    4'd1: mtime[63:32]    <= merge(mtime[63:32],    wdata, wstrb);
                    4'd2: mtimecmp[31:0]  <= merge(mtimecmp[31:0],  wdata, wstrb);
                    4'd3: mtimecmp[63:32] <= merge(mtimecmp[63:32], wdata, wstrb);
                    default: ;
                endcase
            end
        end
    end

    always @(*) begin
        case (word)
            4'd0:    rdata = mtime[31:0];
            4'd1:    rdata = mtime[63:32];
            4'd2:    rdata = mtimecmp[31:0];
            4'd3:    rdata = mtimecmp[63:32];
            default: rdata = 32'd0;
        endcase
    end

    assign mtip = (mtime >= mtimecmp);

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{addr[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
