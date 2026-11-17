// =============================================================
// File:        rtl/ae350_reset_sync.v
// Module:      ae350_reset_sync
// Role:        リセット同期化回路。アサートは非同期、解除は clk に同期させる (2 段の FF)。
//              AE350 の Hazard3 版で、クロックごとのリセット (HRESETN、PRESETN、DDR_RSTN と CPU のリセット) を作る。
//
// Ports:
//   input  wire clk
//   input  wire rst_n_in     非同期リセット (アクティブ Low)
//   output wire rst_n_out    clk に同期して解除されるリセット
// =============================================================

`default_nettype none

module ae350_reset_sync (
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n_out
);

    // 出力を他の FF の非同期リセットに使うので、lint は「同期と非同期の両方に使われている」と判定する。
    // リセット同期化回路はこの形が定石なので、このファイルの中だけで警告を止める
    /* verilator lint_off SYNCASYNCNET */
    reg [1:0] sync;
    /* verilator lint_on SYNCASYNCNET */

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) sync <= 2'b00;
        else           sync <= {sync[0], 1'b1};
    end

    assign rst_n_out = sync[1];

endmodule

`default_nettype wire
