// =============================================================
// File:        ae350/rtl/uart_reset_seq.v
// Module:      uart_reset_seq
// Role:        UART の受信の線を見張り、決まった 8 byte の並び (= 合図) が続けて来たら、AE350 のリセットを入れる回路
//              (= 2026-11-12)。固まったプログラムから、電源を入れ直さずに ROM のローダー (= ae350/sw/loader.c) へ戻すため。
//              FPGA のロジック側の回路で、シミュレーションでも実機でも使う (= ae350/tb/shell_top.v の中に置く)。
//
//   合図: 1B 1B 61 65 33 35 30 21 (= ESC ESC "ae350!")
//
//   - 受信器は CPU の UART (= apb_uart) とは別に持つ (= rtl/vendor/verilog-uart/uart_rx.v)。CPU が UART を読んでいなくても、
//     受信の FIFO があふれていても、合図は見える
//   - 1 byte ずつ照らし、合わない byte が来たら最初から照らし直す。その byte が 1B なら合図の頭として数える
//     (= 1B 1B の後にもう 1 つ 1B が来たら、後ろの 2 つを頭とする)。ストップビットが 0 の byte も、合わない byte として扱う
//   - 合図が揃ったら、rst_out_n を PULSE サイクルの間 0 にする (= AE350 が転送の途中でリセットされても、DDR_H* の先の
//     ahb_sdram がその転送を終えてから、AE350 がリセットから出る長さ)
//   - この回路自身は rst_n (= 電源投入とボタン) でだけリセットする。自分が出すリセットではリセットしない
//   - ROM のローダーが中身を受けている間は hold = 1 なので、送るプログラムの中身にこの 8 byte が並んでいても、リセットは
//     かからない。プログラムの実行中に合図を含む入力を送ると、リセットがかかる
//
// Ports:
//   input  wire clk / rst_n      APB_CLK と、外の全体のリセット (active low、非同期)
//   input  wire rxd              UART の受信の線 (= ピンから非同期に入る。フリップフロップ 2 段で同期させてから受信器に渡す)
//   input  wire hold             1 の間は合図を見張らない (= 受けた byte を照らさず、揃った数を 0 に戻す)。ROM のローダーが
//                                中身を受けている間に、apb_uart の CTRL で 1 にする
//   output reg  rst_out_n        AE350 に入れるリセット (active low)。合図が揃ったら PULSE サイクルの間 0
//
// Parameters:
//   PRESCALE   1 bit の長さ ÷ 8 (= apb_uart と同じ値)
//   PULSE      リセットを入れるサイクルの数 (= 既定 1000。APB_CLK 100 MHz で 10 µs)
// =============================================================

`default_nettype none

module uart_reset_seq #(
    parameter [15:0]  PRESCALE = 16'd108,
    parameter integer PULSE    = 1000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire rxd,
    input  wire hold,
    output reg  rst_out_n
);

    localparam [63:0] SEQ = 64'h1B1B_6165_3335_3021;   // 1 byte 目が上位
    localparam integer PW = $clog2(PULSE + 1);

    // 同期化と、受信器の同期リセット (= rst_n を 1 段で受ける)
    reg [1:0] rxd_sync;
    reg       sync_rst;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_sync <= 2'b11;
            sync_rst <= 1'b1;
        end else begin
            rxd_sync <= {rxd_sync[0], rxd};
            sync_rst <= 1'b0;
        end
    end

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_frame_error;
    /* verilator lint_off PINCONNECTEMPTY */
    uart_rx #(.DATA_WIDTH(8)) u_rx (
        .clk           (clk),
        .rst           (sync_rst),
        .m_axis_tdata  (rx_data),
        .m_axis_tvalid (rx_valid),
        .m_axis_tready (1'b1),
        .rxd           (rxd_sync[1]),
        .busy          (),
        .overrun_error (),              // tready が常に 1 なので起きない
        .frame_error   (rx_frame_error),
        .prescale      (PRESCALE)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // 揃った byte の数 (= 0〜7)。i 番目に待つ byte は SEQ の上から i 番目
    reg [2:0] matched;
    wire [7:0] want = SEQ[63 - 8 * matched -: 8];
    reg [PW-1:0] pulse;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            matched   <= 3'd0;
            pulse     <= {PW{1'b0}};
            rst_out_n <= 1'b1;
        end else begin
            if (hold || rx_frame_error) begin
                matched <= 3'd0;
            end else if (rx_valid) begin
                if (rx_data == want) begin
                    if (matched == 3'd7) begin
                        matched <= 3'd0;
                        pulse   <= PULSE[PW-1:0];
                    end else begin
                        matched <= matched + 3'd1;
                    end
                end else if (rx_data != SEQ[63:56]) begin
                    matched <= 3'd0;
                end else begin
                    // 合わなかった byte が 1B: 合図は 1B 1B で始まるので、2 つ揃っていた (= 1B 1B の次に 1B が来た) なら、
                    // 後ろの 2 つを頭として 2 のまま。それ以外は、この 1B を頭として 1
                    matched <= (matched == 3'd2) ? 3'd2 : 3'd1;
                end
            end
            if (pulse != {PW{1'b0}}) pulse <= pulse - 1'b1;
            rst_out_n <= (pulse == {PW{1'b0}});
        end
    end

endmodule

`default_nettype wire
