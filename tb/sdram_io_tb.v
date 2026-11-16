// =============================================================
// File:        tb/sdram_io_tb.v
// Module:      sdram_io_tb
// Role:        sdram_io (SDRAM のピン周りの回路) の単体テストベンチ。Gowin の IO プリミティブのモデル
//              (tb/gowin_io_models.v) とつなぎ、ピンに出るタイミングと、取り込みのタイミングと遅延を確かめる。期待と違えば $fatal で止まる。
//
//   1  コマンド、アドレス、バンク、DQM は、s_clk のエッジ n で入れた値がエッジ n + 2 からピンに出る
//   2  SDRAM のクロックのピンは s_clk の反転
//   3  DQ は、出力する (dq_oe 1) とエッジ n + 2 から値が出て、出力しない (0) と同じ遅延でハイインピーダンスになる
//   4  立ち上がりで取り込む (CAP_EDGE 0): エッジ m で取り込んだ値が、エッジ m + 3 の後に dq_in に出る
//   5  立ち下がりで取り込む (CAP_EDGE 1): 立ち下がり m - 0.5 で取り込んだ値が、エッジ m + 2 の後に dq_in に出る
//   6  IODELAY: 80 ステップ (1 ns) 遅らせると、エッジの 0.5 ns 前に変わった値はまだ取り込まない (遅らせない側は取り込む)
//
// 実行: make test-sdram-io
// =============================================================

`default_nettype none
`timescale 1ns / 1ps

module sdram_io_tb;

    reg s_clk;
    initial s_clk = 1'b0;
    always #3 s_clk = ~s_clk;        // 166.7 MHz (周期 6 ns)

    reg  [3:0]  cmd    = 4'hF;
    reg  [12:0] addr   = 13'd0;
    reg  [1:0]  ba     = 2'd0;
    reg  [1:0]  dqm    = 2'b11;
    reg  [15:0] dq_out = 16'd0;
    reg         dq_oe  = 1'b0;

    // ピンの DQ をテストベンチから駆動する (SDRAM が読み出した値を返す代わり)。3 つの構成に同じ値を見せる
    reg  [15:0] drive_v  = 16'd0;
    reg         drive_en = 1'b0;

    // 構成 0: 遅延 0、立ち上がり (1〜4、6 の比較の基準側)
    wire [15:0] dq0, dq_in0;
    wire [12:0] a;
    wire [1:0]  b, m;
    wire        ck, cs_n, ras_n, cas_n, we_n;
    assign dq0 = drive_en ? drive_v : 16'hzzzz;
    sdram_io #(.IN_DLY (0), .CAP_EDGE (0)) dut0 (
        .s_clk (s_clk), .cmd (cmd), .addr (addr), .ba (ba), .dqm (dqm), .dq_out (dq_out), .dq_oe (dq_oe), .dq_in (dq_in0),
        .sdram_dq (dq0), .sdram_addr (a), .sdram_ba (b), .sdram_clk (ck), .sdram_cs_n (cs_n),
        .sdram_ras_n (ras_n), .sdram_cas_n (cas_n), .sdram_we_n (we_n), .sdram_dqm (m)
    );

    // 構成 1: 遅延 0、立ち下がり (5)
    wire [15:0] dq1, dq_in1;
    assign dq1 = drive_en ? drive_v : 16'hzzzz;
    /* verilator lint_off PINCONNECTEMPTY */
    sdram_io #(.IN_DLY (0), .CAP_EDGE (1)) dut1 (
        .s_clk (s_clk), .cmd (cmd), .addr (addr), .ba (ba), .dqm (dqm), .dq_out (16'd0), .dq_oe (1'b0), .dq_in (dq_in1),
        .sdram_dq (dq1), .sdram_addr (), .sdram_ba (), .sdram_clk (), .sdram_cs_n (), .sdram_ras_n (), .sdram_cas_n (),
        .sdram_we_n (), .sdram_dqm ()
    );

    // 構成 2: 遅延 80 ステップ (1 ns)、立ち上がり (6)
    wire [15:0] dq2, dq_in2;
    assign dq2 = drive_en ? drive_v : 16'hzzzz;
    sdram_io #(.IN_DLY (80), .CAP_EDGE (0)) dut2 (
        .s_clk (s_clk), .cmd (cmd), .addr (addr), .ba (ba), .dqm (dqm), .dq_out (16'd0), .dq_oe (1'b0), .dq_in (dq_in2),
        .sdram_dq (dq2), .sdram_addr (), .sdram_ba (), .sdram_clk (), .sdram_cs_n (), .sdram_ras_n (), .sdram_cas_n (),
        .sdram_we_n (), .sdram_dqm ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    integer i;

    initial begin
        repeat (4) @(posedge s_clk);

        // 1: エッジ n で入れた値が、エッジ n + 2 からピンに出る
        @(negedge s_clk);
        cmd  <= 4'b0011;
        addr <= 13'h1ABC;
        ba   <= 2'b10;
        dqm  <= 2'b01;
        @(posedge s_clk);                 // エッジ n
        #0.5;
        if ({cs_n, ras_n, cas_n, we_n} === 4'b0011) $fatal(1, "1: 縁 n で、もう出ている");
        @(posedge s_clk);                 // エッジ n + 1
        #0.5;
        if ({cs_n, ras_n, cas_n, we_n} === 4'b0011) $fatal(1, "1: 縁 n + 1 で、もう出ている");
        @(posedge s_clk);                 // エッジ n + 2
        #0.5;
        if ({cs_n, ras_n, cas_n, we_n} !== 4'b0011 || a !== 13'h1ABC || b !== 2'b10 || m !== 2'b01) begin
            $fatal(1, "1: 縁 n + 2 で出ていない (cmd %b addr %h ba %b dqm %b)", {cs_n, ras_n, cas_n, we_n}, a, b, m);
        end
        @(negedge s_clk);
        #0.5;
        if ({cs_n, ras_n, cas_n, we_n} !== 4'b0011) $fatal(1, "1: 半周期後に変わった");
        $display("1 出力の遅れ: 合格");

        // 2: SDRAM のクロックは s_clk の反転
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge s_clk);
            #0.5;
            if (ck !== 1'b0) $fatal(1, "2: s_clk が 1 の間に SDRAM のクロックが 1");
            @(negedge s_clk);
            #0.5;
            if (ck !== 1'b1) $fatal(1, "2: s_clk が 0 の間に SDRAM のクロックが 0");
        end
        $display("2 SDRAM のクロック: 合格");

        // 3: DQ の出力と出力許可 (同じ遅延)
        @(negedge s_clk);
        dq_out <= 16'hBEEF;
        dq_oe  <= 1'b1;
        @(posedge s_clk);                 // エッジ n
        @(negedge s_clk);
        dq_oe  <= 1'b0;
        @(posedge s_clk);                 // エッジ n + 1
        #0.5;
        if (dq0 !== 16'hzzzz) $fatal(1, "3: 縁 n + 1 で、もう DQ を出している (%h)", dq0);
        @(posedge s_clk);                 // エッジ n + 2
        #0.5;
        if (dq0 !== 16'hBEEF) $fatal(1, "3: 縁 n + 2 で DQ が %h", dq0);
        @(posedge s_clk);                 // エッジ n + 3 (出力しない状態に戻した値)
        #0.5;
        if (dq0 !== 16'hzzzz) $fatal(1, "3: 出さないに戻した後も DQ を出している (%h)", dq0);
        $display("3 DQ の出力と許可: 合格");

        // 4 と 5: ピンの値を半周期ごとに変える (立ち下がりの前に 1234、立ち上がりの前に 5678)
        repeat (2) @(posedge s_clk);
        #1;
        drive_en <= 1'b1;
        drive_v  <= 16'h1234;             // 立ち下がり m - 0.5 で取り込まれる値
        @(negedge s_clk);
        #1;
        drive_v  <= 16'h5678;             // 立ち上がり m で取り込まれる値
        @(posedge s_clk);                 // エッジ m
        #1;
        drive_v  <= 16'h9ABC;
        @(posedge s_clk);                 // エッジ m + 1
        #0.5;
        if (dq_in0 === 16'h5678 || dq_in1 === 16'h1234) $fatal(1, "4/5: 縁 m + 1 で、もう出ている");
        @(posedge s_clk);                 // エッジ m + 2
        #0.5;
        if (dq_in0 === 16'h5678) $fatal(1, "4: 縁 m + 2 で、もう出ている");
        if (dq_in1 !== 16'h1234) $fatal(1, "5: 立ち下がりで取った値が、縁 m + 2 の後に %h", dq_in1);
        @(posedge s_clk);                 // エッジ m + 3
        #0.5;
        if (dq_in0 !== 16'h5678) $fatal(1, "4: 立ち上がりで取った値が、縁 m + 3 の後に %h", dq_in0);
        drive_en <= 1'b0;
        $display("4 立ち上がりで取る: 合格");
        $display("5 立ち下がりで取る: 合格");

        // 6: エッジの 0.5 ns 前に値を変える。遅らせない側 (構成 0) は新しい値を、1 ns 遅らせた側 (構成 2) は古い値を取り込む
        repeat (2) @(posedge s_clk);
        drive_en <= 1'b1;
        drive_v  <= 16'h0F0F;
        @(posedge s_clk);
        #5.5;                             // 次のエッジの 0.5 ns 前
        drive_v  <= 16'hF0F0;
        @(posedge s_clk);                 // エッジ m
        #2;
        drive_v  <= 16'h0000;
        repeat (3) @(posedge s_clk);      // エッジ m + 3
        #0.5;
        if (dq_in0 !== 16'hF0F0) $fatal(1, "6: 遅らせない側が %h (= F0F0 を取るはず)", dq_in0);
        if (dq_in2 !== 16'h0F0F) $fatal(1, "6: 1 ns 遅らせた側が %h (= 0F0F を取るはず)", dq_in2);
        drive_en <= 1'b0;
        $display("6 IODELAY: 合格");

        $display("sdram_io_tb: 合格");
        $finish;
    end

endmodule

`default_nettype wire
