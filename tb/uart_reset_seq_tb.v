// =============================================================
// File:        ae350/tb/uart_reset_seq_tb.v
// Module:      uart_reset_seq_tb
// Role:        uart_reset_seq (= UART の合図で AE350 をリセットする回路) の単体の TB (= 2026-11-12)。
//              byte の並びを送り、rst_out_n のパルスの数と長さを数えて、期待と比べる。
//
//   1 合図                                   パルス 1、長さ PULSE
//   2 合図の頭の 7 byte                       パルス 0
//   3 合図の 1 byte を 00 に替えたもの (= 8 か所) パルス 0
//   4 1B 1B 1B + 残り 6 byte                  パルス 1 (= 後ろの 2 つを頭として数える)
//   5 1B 1B 61 で切れて、続けて合図             パルス 1
//   6 途中にストップビットが 0 の byte、続けて合図  途中の分は 0、その後の合図で 1
//   7 合図を 2 回続けて                        パルス 2
//   8 合図の途中で長く止まり、続きを送る          パルス 1 (= 時間で切らない)
//   9 パルスの途中で rst_n                     すぐに 1 に戻り、その後パルスは出ない
//  10 hold = 1 の間に合図                      パルス 0
//  11 合図の 4 byte の後で hold を立てて下ろし、残りの 4 byte  パルス 0。その後の合図で 1
// =============================================================

`timescale 1ns/1ps
`default_nettype none

module uart_reset_seq_tb;

    localparam [15:0]  PRESCALE = 16'd2;    // 1 bit = 16 サイクル
    localparam integer PULSE    = 20;

    reg clk;
    reg rst_n;
    reg rxd;
    reg hold;
    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        rxd   = 1'b1;
        hold  = 1'b0;
    end
    always #5 clk = ~clk;

    wire rst_out_n;

    uart_reset_seq #(.PRESCALE(PRESCALE), .PULSE(PULSE)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .rxd       (rxd),
        .hold      (hold),
        .rst_out_n (rst_out_n)
    );

    // パルスの数と、最後のパルスの長さ (= rst_out_n が 0 だったサイクル数)。rst_n で 0 に戻る
    integer pulses;
    integer width;
    integer cur;
    reg     prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pulses <= 0;
            width  <= 0;
            cur    <= 0;
            prev   <= 1'b1;
        end else begin
            prev <= rst_out_n;
            cur  <= rst_out_n ? 0 : cur + 1;
            if (prev && !rst_out_n) pulses <= pulses + 1;
            if (!prev && rst_out_n) width <= cur;
        end
    end

    task send_bit(input b);
        begin
            rxd = b;
            repeat (PRESCALE * 8) @(posedge clk);
        end
    endtask

    task send_byte(input [7:0] d, input bad_stop);
        integer k;
        begin
            send_bit(1'b0);
            for (k = 0; k < 8; k = k + 1) send_bit(d[k]);
            send_bit(!bad_stop);
            rxd = 1'b1;
            repeat (PRESCALE * 8) @(posedge clk);
        end
    endtask

    localparam [63:0] SEQ = 64'h1B1B_6165_3335_3021;

    // 合図の i byte 目から j byte 目の手前までを送る
    task send_seq(input integer from, input integer to);
        integer k;
        begin
            for (k = from; k < to; k = k + 1) send_byte(SEQ[63 - 8 * k -: 8], 1'b0);
        end
    endtask

    // パルスが出きるまで待ってから、前回からの増え分を照らす
    integer base;
    task expect_pulses(input integer n, input [8*48-1:0] what);
        begin
            repeat (PULSE + 40) @(posedge clk);
            if (pulses - base != n) $fatal(1, "%0s: パルスが %0d (= %0d のはず)", what, pulses - base, n);
            base = pulses;
        end
    endtask

    integer pos, k;

    initial begin
        base = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        if (rst_out_n !== 1'b1) $fatal(1, "リセットの後に rst_out_n が 1 でない");

        // 1
        send_seq(0, 8);
        expect_pulses(1, "1 合図");
        if (width != PULSE) $fatal(1, "1 合図: パルスの長さが %0d (= %0d のはず)", width, PULSE);
        $display("1 合図: 合格 (= 長さ %0d)", width);

        // 2
        send_seq(0, 7);
        send_byte(8'h00, 1'b0);
        expect_pulses(0, "2 頭の 7 byte");
        $display("2 頭の 7 byte: 合格");

        // 3
        for (pos = 0; pos < 8; pos = pos + 1) begin
            for (k = 0; k < 8; k = k + 1) send_byte((k == pos) ? 8'h00 : SEQ[63 - 8 * k -: 8], 1'b0);
            expect_pulses(0, "3 1 byte 違い");
        end
        $display("3 1 byte 違い (= 8 か所): 合格");

        // 4
        send_byte(8'h1B, 1'b0);
        send_seq(0, 8);
        expect_pulses(1, "4 1B 1B 1B");
        $display("4 1B 1B 1B: 合格");

        // 5
        send_seq(0, 3);
        send_seq(0, 8);
        expect_pulses(1, "5 1B 1B 61 で切れる");
        $display("5 1B 1B 61 で切れる: 合格");

        // 6
        send_seq(0, 4);
        send_byte(SEQ[63 - 8 * 4 -: 8], 1'b1);   // 5 byte 目を、ストップビット 0 で
        send_seq(5, 8);
        expect_pulses(0, "6 ストップビット 0");
        send_seq(0, 8);
        expect_pulses(1, "6 その後の合図");
        $display("6 ストップビット 0: 合格");

        // 7
        send_seq(0, 8);
        repeat (PULSE + 40) @(posedge clk);
        send_seq(0, 8);
        expect_pulses(2, "7 2 回");
        $display("7 2 回: 合格");

        // 8
        send_seq(0, 4);
        repeat (100000) @(posedge clk);
        send_seq(4, 8);
        expect_pulses(1, "8 途中で長く止まる");
        $display("8 途中で長く止まる: 合格");

        // 9 (= 最後の 1 byte を送っている途中で、パルスが出るのを待ち、その 4 サイクル後に rst_n を入れる)
        send_seq(0, 7);
        fork
            send_seq(7, 8);
        join_none
        k = 0;
        while (rst_out_n !== 1'b0 && k < PRESCALE * 8 * 12) begin
            @(posedge clk);
            k = k + 1;
        end
        if (rst_out_n !== 1'b0) $fatal(1, "9: 合図の後にパルスが出ていない");
        repeat (4) @(posedge clk);
        if (rst_out_n !== 1'b0) $fatal(1, "9: パルスが 4 サイクルで終わった");
        rst_n = 1'b0;
        #1;
        if (rst_out_n !== 1'b1) $fatal(1, "9: rst_n で rst_out_n が 1 に戻らない");
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (PULSE * 3) @(posedge clk);
        if (pulses != 0 || rst_out_n !== 1'b1) $fatal(1, "9: rst_n の後にパルスが出た");
        $display("9 パルスの途中で rst_n: 合格");
        base = pulses;

        // 10
        hold = 1'b1;
        send_seq(0, 8);
        expect_pulses(0, "10 hold = 1 の間の合図");
        hold = 1'b0;
        $display("10 hold = 1 の間の合図: 合格");

        // 11
        send_seq(0, 4);
        hold = 1'b1;
        repeat (4) @(posedge clk);
        hold = 1'b0;
        send_seq(4, 8);
        expect_pulses(0, "11 途中で hold");
        send_seq(0, 8);
        expect_pulses(1, "11 その後の合図");
        $display("11 途中で hold: 合格");

        $display("uart_reset_seq_tb: 合格");
        $finish;
    end

endmodule

`default_nettype wire
