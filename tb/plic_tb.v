// =============================================================
// File:        tb/plic_tb.v
// Module:      plic_tb
// Role:        ae350_plic の単体テストベンチ。Hazard3 版の全体のテストベンチ (tb_mem) は全ソースがレベル割り込みの構成
//              なので、ここではエッジのソースを持つ構成と、claim をしきい値で絞らない構成 (CLAIM_ABOVE_THRESHOLD = 0)
//              を確かめる。期待と違えば $fatal で止まる。
//
//   u_edge   EDGE_TRIGGER = ソース 5 だけエッジ (ソース 6 はレベル)
//   u_nothr  CLAIM_ABOVE_THRESHOLD = 0
//
// 実行: make test-plic
// =============================================================

`default_nettype none

module plic_tb;

    reg clk;
    reg rst_n;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
    end

    always #5 clk = ~clk;

    // ---------------------------------------------------------
    // 2 つの構成。バスの信号は共有し、sel で読み書きする方を選ぶ
    // ---------------------------------------------------------
    reg  [31:1] src;
    reg         wen;
    reg         ren;
    reg         sel;          // 0 = u_edge、1 = u_nothr
    reg  [21:0] addr;
    reg  [31:0] wdata;
    wire [31:0] rdata_edge;
    wire [31:0] rdata_nothr;
    wire        meip_edge;
    wire        meip_nothr;

    // seip (ターゲット 1 への通知) はここでは見ない (sw/stage4_test.c がレジスタで確かめる)
    /* verilator lint_off PINCONNECTEMPTY */
    ae350_plic #(
        .EDGE_TRIGGER (32'h0000_0020)
    ) u_edge (
        .clk   (clk),
        .rst_n (rst_n),
        .src   (src),
        .wen   (wen && !sel),
        .ren   (ren && !sel),
        .addr  (addr),
        .wdata (wdata),
        .wstrb (4'hF),
        .rdata (rdata_edge),
        .meip  (meip_edge),
        .seip  ()
    );

    ae350_plic #(
        .CLAIM_ABOVE_THRESHOLD (0)
    ) u_nothr (
        .clk   (clk),
        .rst_n (rst_n),
        .src   (src),
        .wen   (wen && sel),
        .ren   (ren && sel),
        .addr  (addr),
        .wdata (wdata),
        .wstrb (4'hF),
        .rdata (rdata_nothr),
        .meip  (meip_nothr),
        .seip  ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    localparam [21:0] A_PENDING   = 22'h00_1000;
    localparam [21:0] A_TRIGGER   = 22'h00_1080;
    localparam [21:0] A_ENABLE    = 22'h00_2000;
    localparam [21:0] A_THRESHOLD = 22'h20_0000;
    localparam [21:0] A_CLAIM     = 22'h20_0004;

    // 1 サイクルの書き込み
    task wr(input s, input [21:0] a, input [31:0] d);
        begin
            sel = s; addr = a; wdata = d; wen = 1'b1;
            @(posedge clk); #1;
            wen = 1'b0;
        end
    endtask

    // 1 サイクルの読み出し (claim なら副作用が起きる)。読む前に 1 サイクル空ける (PLIC は、選んだ割り込みを
    // レジスタで受けてから claim と通知に使うので、pending や enable の変化が見えるのは 1 サイクル後。CPU のバスでは、
    // 続けて読むまでに何サイクルもかかる)
    task rd(input s, input [21:0] a, output [31:0] d);
        begin
            @(posedge clk); #1;
            sel = s; addr = a; ren = 1'b1;
            #1 d = s ? rdata_nothr : rdata_edge;
            @(posedge clk); #1;
            ren = 1'b0;
        end
    endtask

    task expect32(input [31:0] got, input [31:0] want, input integer no);
        begin
            if (got !== want) $fatal(1, "確認 %0d: 0x%08x を期待したが 0x%08x", no, want, got);
        end
    endtask

    // ソース n に 1 サイクルのパルスを出す
    task pulse(input integer n);
        begin
            src[n] = 1'b1;
            @(posedge clk); #1;
            src[n] = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    reg [31:0] v;

    initial begin
        src = 31'd0; wen = 1'b0; ren = 1'b0; sel = 1'b0; addr = 22'd0; wdata = 32'd0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;

        // ---- エッジのソース (u_edge のソース 5) ----
        rd(0, A_TRIGGER, v);            expect32(v, 32'h0000_0020, 1);   // trigger はパラメータのとおり
        wr(0, A_ENABLE, 32'h0000_0060);                                   // ソース 5 と 6

        pulse(5);
        rd(0, A_PENDING, v);            expect32(v, 32'h0000_0020, 2);   // 立ち上がりで pending になる
        pulse(5);                                                         // 停止している間のエッジは捨てる
        rd(0, A_CLAIM, v);              expect32(v, 32'd5, 3);
        rd(0, A_PENDING, v);            expect32(v, 32'h0, 4);
        pulse(5);                                                         // claim の後、complete の前のエッジも捨てる
        rd(0, A_PENDING, v);            expect32(v, 32'h0, 5);
        wr(0, A_CLAIM, 32'd5);                                            // complete
        @(posedge clk); #1;
        rd(0, A_PENDING, v);            expect32(v, 32'h0, 6);           // 捨てたエッジは数えていない
        src[5] = 1'b1;                                                    // 立ち上がり、1 のまま保つ
        @(posedge clk); #1;
        rd(0, A_CLAIM, v);              expect32(v, 32'd5, 7);
        wr(0, A_CLAIM, 32'd5);
        repeat (3) @(posedge clk); #1;
        rd(0, A_PENDING, v);            expect32(v, 32'h0, 8);           // エッジは、1 のままでは再び pending にならない
        src[5] = 1'b0;

        // ---- 同じ構成のレベルのソース (ソース 6) ----
        src[6] = 1'b1;
        @(posedge clk); #1;
        rd(0, A_CLAIM, v);              expect32(v, 32'd6, 9);
        wr(0, A_CLAIM, 32'd6);
        repeat (2) @(posedge clk); #1;
        rd(0, A_PENDING, v);            expect32(v, 32'h0000_0040, 10);  // レベルは、1 のままなら再び pending になる
        src[6] = 1'b0;
        rd(0, A_CLAIM, v);              expect32(v, 32'd6, 11);
        wr(0, A_CLAIM, 32'd6);

        // ---- claim がしきい値で絞らない構成 (u_nothr) ----
        wr(1, A_ENABLE, 32'h0000_0080);                                   // ソース 7 (優先度は初期値の 1)
        wr(1, A_THRESHOLD, 32'd3);
        src[7] = 1'b1;
        repeat (2) @(posedge clk); #1;
        if (meip_nothr) $fatal(1, "確認 12: 優先度 1 は しきい値 3 では通知されないはず");
        rd(1, A_CLAIM, v);              expect32(v, 32'd7, 13);          // 通知はないが、claim は番号を返す
        src[7] = 1'b0;
        wr(1, A_CLAIM, 32'd7);

        // 同じことを、しきい値で絞る構成 (u_edge) でも確かめる
        wr(0, A_ENABLE, 32'h0000_0080);
        wr(0, A_THRESHOLD, 32'd3);
        src[7] = 1'b1;
        repeat (2) @(posedge clk); #1;
        rd(0, A_CLAIM, v);              expect32(v, 32'd0, 14);          // しきい値で絞るので 0
        src[7] = 1'b0;

        // ---- claim を間を空けずに続けて読む (選んだ結果はレジスタで受けるので、クリアした番号が 1 サイクル残る。
        //      claim を読んだサイクルにはレジスタを 0 にするので、続けて読んでも同じ番号を 2 回返さない) ----
        wr(0, A_THRESHOLD, 32'd0);
        wr(0, A_ENABLE, 32'h0000_00C0);                                   // ソース 6 と 7 (どちらもレベル、優先度 1)
        src[6] = 1'b1;
        src[7] = 1'b1;
        repeat (3) @(posedge clk); #1;
        sel = 1'b0; addr = A_CLAIM; ren = 1'b1;
        #1 v = rdata_edge;              expect32(v, 32'd6, 15);          // 優先度が同じなら番号の小さい方
        @(posedge clk); #1;
        v = rdata_edge;                 expect32(v, 32'd0, 16);          // 続けて読むと 0 (6 を 2 回返さない)
        @(posedge clk); #1;
        ren = 1'b0;
        rd(0, A_CLAIM, v);              expect32(v, 32'd7, 17);          // 間を空けて読むと次の 7
        src[6] = 1'b0;
        src[7] = 1'b0;
        wr(0, A_CLAIM, 32'd6);
        wr(0, A_CLAIM, 32'd7);

        $display("plic_tb: 合格");
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{meip_edge};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
