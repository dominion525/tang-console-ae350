// =============================================================
// File:        rtl/ae350_plmt.v
// Module:      ae350_plmt
// Role:        AE350 の Hazard3 版の PLMT (Platform Level Machine Timer)。
//              レジスタの配置は MUG1029 の表 15-1 に合わせる (hart 0 だけ)。
//
// Registers (Hazard3 版の中央バスが、0xE600_0000 からのオフセットで渡す):
//   0x00  MTIME[31:0]       0x04  MTIME[63:32]       R/W   clk の 1 サイクルごとに 1 増える。初期値 0
//   0x08  MTIMECMP0[31:0]   0x0C  MTIMECMP0[63:32]   R/W   初期値 0xFFFF_FFFF_FFFF_FFFF
//   それ以外                                            読み出しは 0。書き込みは無視する
//
// mtime のクロック: Gowin の BSP (ae350.h の OSCFREQ = HCLKFREQ = 100 MHz) と PLMT のデモ (demo_plmt.c の
// MACHINE_TIMER_PERIOD = 2 * OSCFREQ が 2 秒) は、mtime がバスのクロック (リファレンスデザインの AHB_CLK と
// APB_CLK、100 MHz) で進むことを前提にしている。同じデザインの RTC_CLK は 10 MHz なので、mtime は RTC_CLK では
// 進まない。Hazard3 版は、AHB_CLK (clk) の 1 サイクルごとに mtime を進める
//
// Ports:
//   input  wire        clk / rst_n     AHB_CLK と、Hazard3 版のリセット。mtime もこのクロックで進む
//   input  wire        wen             このサイクルに書き込む
//   input  wire [5:0]  addr            バイトオフセット (下位 2 ビットは見ない)
//   input  wire [31:0] wdata
//   input  wire [3:0]  wstrb           書き込むバイトレーン
//   output reg  [31:0] rdata           addr で選んだレジスタの値 (組み合わせ回路)
//   output wire        mtip            mtime >= mtimecmp0 (レベル)
//
// Design Notes:
//   - mtime に書き込んだサイクルは、書き込んだ側の 32 ビットが書き込んだ値になり、カウントは進まない
//   - 64 ビットのレジスタは 32 ビットずつ読み書きする。上位と下位を続けて読む間に桁上がりすると値が食い違うので、
//     ソフトウェアは「上位、下位、上位」の順に読み、2 回の上位が同じことを確かめる (RISC-V の標準的な読み方)
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

    // バイトレーンを選んで書き込んだ値
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
