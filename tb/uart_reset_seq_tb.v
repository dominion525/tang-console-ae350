// =============================================================
// File:        tb/uart_reset_seq_tb.v
// Module:      uart_reset_seq_tb
// Role:        uart_reset_seq (UART のリセットシーケンスで AE350 をリセットする回路) の単体テストベンチ。
//              バイト列を送り、rst_out_n のパルスの数と長さを数えて、期待と比べる。
//
//   1 シーケンス                                      パルス 1、長さ PULSE
//   2 シーケンスの先頭 7 バイト                        パルス 0
//   3 シーケンスの 1 バイトを 00 に替えたもの (8 通り)   パルス 0
//   4 1B 1B 1B + 残りの 6 バイト                       パルス 1 (後ろの 2 つを先頭として数える)
//   5 1B 1B 61 で途切れ、続けてシーケンス               パルス 1
//   6 途中にストップビットが 0 のバイト、続けてシーケンス  途中の分は 0、その後のシーケンスで 1
//   7 シーケンスを 2 回続けて                          パルス 2
//   8 シーケンスの途中で長く止まり、続きを送る           パルス 1 (時間で区切らない)
//   9 パルスの途中で rst_n                             すぐに 1 に戻り、その後パルスは出ない
//  10 hold = 1 の間にシーケンス                        パルス 0
//  11 シーケンスの 4 バイトの後で hold を 1 にして 0 に戻し、残りの 4 バイト  パルス 0。その後のシーケンスで 1
// =============================================================

`timescale 1ns/1ps
`default_nettype none

module uart_reset_seq_tb;

    localparam [15:0]  PRESCALE = 16'd2;    // 1 ビット = 16 サイクル
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

    // パルスの数と、最後のパルスの長さ (rst_out_n が 0 だったサイクル数)。rst_n で 0 に戻る
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

    // シーケンスの i バイト目から、j バイト目の手前までを送る
    task send_seq(input integer from, input integer to);
        integer k;
        begin
            for (k = from; k < to; k = k + 1) send_byte(SEQ[63 - 8 * k -: 8], 1'b0);
        end
    endtask

    // パルスが出終わるまで待ってから、前回からの増加分を照合する
    integer base;
    task expect_pulses(input integer n, input [8*48-1:0] what);
        begin
            repeat (PULSE + 40) @(posedge clk);
            if (pulses - base != n) $fatal(1, "%0s: %0d pulses (expected %0d)", what, pulses - base, n);
            base = pulses;
        end
    endtask

    integer pos, k;

    initial begin
        base = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        if (rst_out_n !== 1'b1) $fatal(1, "rst_out_n is not 1 after reset");

        // 1
        send_seq(0, 8);
        expect_pulses(1, "1 sequence");
        if (width != PULSE) $fatal(1, "1 sequence: pulse width %0d (expected %0d)", width, PULSE);
        $display("1 sequence: PASS (width %0d)", width);

        // 2
        send_seq(0, 7);
        send_byte(8'h00, 1'b0);
        expect_pulses(0, "2 first 7 bytes");
        $display("2 first 7 bytes: PASS");

        // 3
        for (pos = 0; pos < 8; pos = pos + 1) begin
            for (k = 0; k < 8; k = k + 1) send_byte((k == pos) ? 8'h00 : SEQ[63 - 8 * k -: 8], 1'b0);
            expect_pulses(0, "3 one byte different");
        end
        $display("3 one byte different (8 positions): PASS");

        // 4
        send_byte(8'h1B, 1'b0);
        send_seq(0, 8);
        expect_pulses(1, "4 1B 1B 1B");
        $display("4 1B 1B 1B: PASS");

        // 5
        send_seq(0, 3);
        send_seq(0, 8);
        expect_pulses(1, "5 cut off after 1B 1B 61");
        $display("5 cut off after 1B 1B 61: PASS");

        // 6
        send_seq(0, 4);
        send_byte(SEQ[63 - 8 * 4 -: 8], 1'b1);   // 5 バイト目を、ストップビット 0 で送る
        send_seq(5, 8);
        expect_pulses(0, "6 stop bit 0");
        send_seq(0, 8);
        expect_pulses(1, "6 sequence afterwards");
        $display("6 stop bit 0: PASS");

        // 7
        send_seq(0, 8);
        repeat (PULSE + 40) @(posedge clk);
        send_seq(0, 8);
        expect_pulses(2, "7 twice");
        $display("7 twice: PASS");

        // 8
        send_seq(0, 4);
        repeat (100000) @(posedge clk);
        send_seq(4, 8);
        expect_pulses(1, "8 long pause midway");
        $display("8 long pause midway: PASS");

        // 9 (最後の 1 バイトを送っている途中でパルスが出るのを待ち、その 4 サイクル後に rst_n をアサートする)
        send_seq(0, 7);
        fork
            send_seq(7, 8);
        join_none
        k = 0;
        while (rst_out_n !== 1'b0 && k < PRESCALE * 8 * 12) begin
            @(posedge clk);
            k = k + 1;
        end
        if (rst_out_n !== 1'b0) $fatal(1, "9: no pulse after the sequence");
        repeat (4) @(posedge clk);
        if (rst_out_n !== 1'b0) $fatal(1, "9: pulse ended after 4 cycles");
        rst_n = 1'b0;
        #1;
        if (rst_out_n !== 1'b1) $fatal(1, "9: rst_out_n does not return to 1 on rst_n");
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (PULSE * 3) @(posedge clk);
        if (pulses != 0 || rst_out_n !== 1'b1) $fatal(1, "9: pulse after rst_n");
        $display("9 rst_n during pulse: PASS");
        base = pulses;

        // 10
        hold = 1'b1;
        send_seq(0, 8);
        expect_pulses(0, "10 sequence while hold = 1");
        hold = 1'b0;
        $display("10 sequence while hold = 1: PASS");

        // 11
        send_seq(0, 4);
        hold = 1'b1;
        repeat (4) @(posedge clk);
        hold = 1'b0;
        send_seq(4, 8);
        expect_pulses(0, "11 hold midway");
        send_seq(0, 8);
        expect_pulses(1, "11 sequence afterwards");
        $display("11 hold midway: PASS");

        $display("uart_reset_seq_tb: PASS");
        $finish;
    end

endmodule

`default_nettype wire
