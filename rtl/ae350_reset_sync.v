// =============================================================
// File:        ae350/rtl/ae350_reset_sync.v
// Module:      ae350_reset_sync
// Role:        リセットの同期 (= 段 4 の後、2026-11-10)。かかるのは非同期、解けるのは clk に同期 (= 2 段)。
//              AE350 のモックで、クロックごとのリセット (= HRESETN / PRESETN / DDR_RSTN と CPU のリセット) を作る。
//
// Ports:
//   input  wire clk
//   input  wire rst_n_in     非同期のリセット (active low)
//   output wire rst_n_out    clk に同期して解けるリセット
// =============================================================

`default_nettype none

module ae350_reset_sync (
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n_out
);

    // 出力をほかのフリップフロップの非同期リセットに使うので、lint は「同期と非同期の両方に使われる」と見る。
    // リセットの同期はこの形が決まりなので、このファイルの中だけで止める
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
