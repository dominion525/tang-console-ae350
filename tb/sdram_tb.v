// =============================================================
// File:        tb/sdram_tb.v
// Module:      sdram_tb
// Role:        ahb_sdram (= DDR_H* から SDRAM の制御へつなぐ回路) の単体の TB (= 2026-11-11)。
//              ahb_sdram → rtl/sdram_bridge.v → SDRAM のモデルをつなぎ、AHB の転送を TB から出して確かめる。
//              破れたら $fatal で止まる。
//
//   1  初期化の前に来た読み出しが、待たされた後に正しく終わる
//   2  HSIZE 0〜3 と番地の下位のすべての組み合わせで書き、すべての HSIZE で読み返して写しと比べる
//   3  16 byte の行の上下 (= 番地の bit 3) の両方
//   4  32 MB の外の読みと書き: エラー応答が 2 サイクルで、SDRAM の中身は変わらない
//   5  転送を間を空けずに続ける (= 前の転送が終わる縁で、次のアドレスフェーズを出す)
//   6  32 MB の一番上の 8 byte
//   7  乱数の番地と HSIZE で読み書きし、写しと比べる
//   8  転送を待っている途中のリセットの後も、正しく動く
//
// 実行: make test-sdram-unit
// =============================================================

`default_nettype none
`timescale 1ns / 1ps

module sdram_tb;

    reg hclk;
    reg sclk;
    initial begin
        hclk = 1'b0;
        sclk = 1'b0;
    end
    always #10 hclk = ~hclk;    // 50 MHz (= DDR_CLK)
`ifdef SDRAM_HS
    // 166.7 MHz 版: s_clk 6 ns。読んだデータを取る位置は、定義 SDRAM_IN_DLY (= IODELAY の刻み) と SDRAM_CAP_EDGE で渡す
    always #3 sclk = ~sclk;
    localparam integer SCLK_PS = 6000;
`else
    always #25 sclk = ~sclk;    // 20 MHz (= SDRAM)
    localparam integer SCLK_PS = 50000;
`endif
    localparam integer HCLK_PS = 20000;

    reg rst_n = 1'b0;

    // SDRAM の側のリセット (= sclk に同期させる)
    /* verilator lint_off SYNCASYNCNET */
    reg [1:0] srst_s;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge sclk or negedge rst_n) begin
        if (!rst_n) srst_s <= 2'b00;
        else        srst_s <= {srst_s[0], 1'b1};
    end
    wire srst_n = srst_s[1];

    // AHB (= TB がマスタ)
    reg  [31:0] haddr  = 32'd0;
    reg  [1:0]  htrans = 2'b00;
    reg         hwrite = 1'b0;
    reg  [2:0]  hsize  = 3'd0;
    reg  [63:0] hwdata = 64'd0;
    wire [63:0] hrdata;
    wire        hready;
    wire        hresp;

    wire          fill_valid, fill_ready, we, wready, init_done;
    wire [20:0]   fill_line;
    wire [127:0]  fill_data;
    wire [24:0]   waddr;
    wire [7:0]    wdata;
`ifndef SDRAM_HS
    wire [15:0]   dq;
    wire [12:0]   a;
    wire [1:0]    ba, dqm;
    wire          cs_n, ras_n, cas_n, we_n;
`endif

    ahb_sdram #(.SDRAM_AW(25)) dut (
        .hclk (hclk), .hresetn (rst_n), .haddr (haddr), .htrans (htrans), .hwrite (hwrite), .hsize (hsize),
        .hwdata (hwdata), .hrdata (hrdata), .hreadyout (hready), .hresp (hresp),
        .sclk (sclk), .srst_n (srst_n), .fill_valid (fill_valid), .fill_line (fill_line), .fill_ready (fill_ready),
        .fill_data (fill_data), .we (we), .waddr (waddr), .wdata (wdata), .wready (wready)
    );

`ifdef SDRAM_HS
`ifndef SDRAM_BOARD_PS
    `define SDRAM_BOARD_PS 0
`endif
`ifndef SDRAM_RD_FIRST
    `define SDRAM_RD_FIRST 11
`endif
`ifndef SDRAM_IN_DLY
    `define SDRAM_IN_DLY 160
`endif
`ifndef SDRAM_CAP_EDGE
    `define SDRAM_CAP_EDGE 0
`endif
    sdram_hs_path #(.ADDR_WIDTH(25), .BOARD_PS(`SDRAM_BOARD_PS), .RD_FIRST(`SDRAM_RD_FIRST), .IN_DLY(`SDRAM_IN_DLY),
                    .CAP_EDGE(`SDRAM_CAP_EDGE)) u_path (
        .s_clk (sclk), .rst_n (srst_n), .fill_valid (fill_valid), .fill_line (fill_line),
        .fill_ready (fill_ready), .fill_data (fill_data), .we (we), .waddr (waddr), .wdata (wdata), .wready (wready),
        .init_done (init_done)
    );
    `define SDRAM_MEM u_path.u_model.mem
`else
    `define SDRAM_MEM u_model.mem
    sdram_bridge #(.ADDR_WIDTH(25)) u_bridge (
        .clk (sclk), .rst_n (srst_n), .fill_valid (fill_valid), .fill_line (fill_line), .fill_ready (fill_ready),
        .fill_data (fill_data), .we (we), .waddr (waddr), .wdata (wdata), .wready (wready), .init_done (init_done),
        .sdram_dq (dq), .sdram_addr (a), .sdram_ba (ba), .sdram_cs_n (cs_n), .sdram_ras_n (ras_n),
        .sdram_cas_n (cas_n), .sdram_we_n (we_n), .sdram_dqm (dqm)
    );

    sdram_model u_model (
        .clk (~sclk), .cke (1'b1), .csn (cs_n), .rasn (ras_n), .casn (cas_n), .wen (we_n), .dqm (dqm), .ba (ba),
        .addr (a), .dq (dq)
    );
`endif

    // ---------------------------------------------------------
    // 写し (= 下の 4 KB と、32 MB の一番上の 4 KB)
    // ---------------------------------------------------------
    reg [7:0] shadow_lo [0:4095];
    reg [7:0] shadow_hi [0:4095];
    integer   i;

    /* verilator lint_off UNUSEDSIGNAL */
    function [11:0] sidx(input [31:0] ad);   // 下位 12 bit (= 4 KB の中の位置)
        sidx = ad[11:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    task shadow_write(input [31:0] ad, input [7:0] v);
        begin
            if (ad < 32'h1000)              shadow_lo[sidx(ad)] = v;
            else if (ad >= 32'h01FF_F000)   shadow_hi[sidx(ad)] = v;
        end
    endtask

    function [7:0] shadow_read(input [31:0] ad);
        shadow_read = (ad < 32'h1000) ? shadow_lo[sidx(ad)] : shadow_hi[sidx(ad)];
    endfunction

    // HSIZE と番地の下位から、バイトレーンの mask
    function [7:0] lane_mask(input [2:0] ad, input [2:0] size);
        case (size)
            3'd0:    lane_mask = 8'b0000_0001 << ad;
            3'd1:    lane_mask = 8'b0000_0011 << {ad[2:1], 1'b0};
            3'd2:    lane_mask = 8'b0000_1111 << {ad[2], 2'b00};
            default: lane_mask = 8'b1111_1111;
        endcase
    endfunction

    // ---------------------------------------------------------
    // AHB の転送 (= 1 つずつ。アドレスフェーズ → データフェーズ)
    // ---------------------------------------------------------
    reg [63:0] rd_data;
    reg        rd_err;
    integer    n_checks;

    // アドレスフェーズを出し、HREADY = 1 の縁で受け付けられるまで保つ
    task addr_phase(input [31:0] ad, input wr, input [2:0] size);
        begin
            haddr  <= ad;
            hwrite <= wr;
            hsize  <= size;
            htrans <= 2'b10;
            @(posedge hclk);
            while (!hready) @(posedge hclk);
        end
    endtask

    // データフェーズ: 書く値を出し、HREADY = 1 の縁まで待って応答を取る。エラーは 2 サイクルの形を確かめる
    task data_phase(input [63:0] wd, input last);
        begin
            hwdata <= wd;
            if (last) htrans <= 2'b00;
            #1;
            while (!hready) begin
                if (hresp) begin
                    // エラー応答の 1 サイクル目 (= HREADY 0)。次の縁で 2 サイクル目 (= HREADY 1、HRESP 1)
                    @(posedge hclk);
                    #1;
                    if (!(hready && hresp)) $fatal(1, "エラー応答の 2 サイクル目の形が違う (hready=%b hresp=%b)", hready, hresp);
                end else begin
                    @(posedge hclk);
                    #1;
                end
            end
            rd_err  = hresp;
            rd_data = hrdata;
            @(posedge hclk);
        end
    endtask

    task ahb_write(input [31:0] ad, input [2:0] size, input [63:0] wd);
        integer k;
        reg [7:0] m;
        begin
            addr_phase(ad, 1'b1, size);
            data_phase(wd, 1'b1);
            if (rd_err) $fatal(1, "書き込み 0x%08x がエラー応答", ad);
            m = lane_mask(ad[2:0], size);
            for (k = 0; k < 8; k = k + 1) if (m[k]) shadow_write({ad[31:3], 3'd0} + k, wd[k*8 +: 8]);
        end
    endtask

    task ahb_read_check(input [31:0] ad, input [2:0] size);
        integer k;
        reg [7:0] m;
        begin
            addr_phase(ad, 1'b0, size);
            data_phase(64'd0, 1'b1);
            if (rd_err) $fatal(1, "読み出し 0x%08x がエラー応答", ad);
            m = lane_mask(ad[2:0], size);
            for (k = 0; k < 8; k = k + 1) begin
                if (m[k] && rd_data[k*8 +: 8] !== shadow_read({ad[31:3], 3'd0} + k)) begin
                    $fatal(1, "読み出し 0x%08x (HSIZE %0d) の byte %0d が %02x、写しは %02x", ad, size, k,
                           rd_data[k*8 +: 8], shadow_read({ad[31:3], 3'd0} + k));
                end
            end
            n_checks = n_checks + 1;
        end
    endtask

    // カウンタ (= ahb_sdram の STAT_BASE、0x0300_0000) を 32 bit で読む。+0x00〜+0x18 の 7 つ
    localparam [31:0] STAT_BASE = 32'h0300_0000;
    reg [31:0] st_before [0:6];
    reg [31:0] st_after  [0:6];

    task stat_read(input integer k, output [31:0] v);
        begin
            addr_phase(STAT_BASE + 4 * k, 1'b0, 3'd2);
            data_phase(64'd0, 1'b1);
            if (rd_err) $fatal(1, "カウンタ +0x%02x の読み出しがエラー応答", 4 * k);
            v = k[0] ? rd_data[63:32] : rd_data[31:0];
        end
    endtask

    // 全部のバイトを、8 byte の読み出しで写しと比べる
    task check_region(input [31:0] base, input integer len);
        integer k;
        begin
            for (k = 0; k < len; k = k + 8) ahb_read_check(base + k, 3'd3);
        end
    endtask

    // ---------------------------------------------------------
    // 本体
    // ---------------------------------------------------------
    integer    sz, off, r, seed;
    reg [63:0] pat;
    reg [31:0] ad;

    initial begin
        n_checks = 0;
        seed     = 1;
        // 写しは、SDRAM のモデルの中身と同じく 0xA5 で始める
        for (i = 0; i < 4096; i = i + 1) begin
            shadow_lo[i] = 8'hA5;
            shadow_hi[i] = 8'hA5;
        end
        for (i = 0; i < 2048; i = i + 1) begin
            `SDRAM_MEM[mi(i * 2)]                = 16'hA5A5;
            `SDRAM_MEM[mi(32'h01FF_F000 + i * 2)] = 16'hA5A5;
        end

        repeat (3) @(posedge hclk);
        rst_n = 1'b1;

        // 1: 初期化の前に来た読み出し (= sdram_bridge は初期化が済むまで受けない)
        if (init_done) $fatal(1, "初期化が早すぎる (= この確認の前提が崩れた)");
        ahb_read_check(32'h0000_0010, 3'd3);
        if (!init_done) $fatal(1, "初期化の前に読み出しが終わった");
        $display("1 初期化の前の読み出し: 合格");

        // 2: HSIZE 0〜3 と番地の下位のすべての組み合わせ
        for (sz = 0; sz < 4; sz = sz + 1) begin
            for (off = 0; off < 8; off = off + (1 << sz)) begin
                pat = {8{sz[1:0], off[2:0], 3'b101}} ^ 64'h0123_4567_89AB_CDEF;
                ahb_write(32'h0000_0100 + sz * 16 + off, sz[2:0], pat);
            end
        end
        for (sz = 0; sz < 4; sz = sz + 1) begin
            for (off = 0; off < 64; off = off + (1 << sz)) ahb_read_check(32'h0000_0100 + off, sz[2:0]);
        end
        $display("2 HSIZE と番地の下位の組み合わせ: 合格");

        // 3: 16 byte の行の上下
        ahb_write(32'h0000_0200, 3'd3, 64'h1111_2222_3333_4444);
        ahb_write(32'h0000_0208, 3'd3, 64'h5555_6666_7777_8888);
        ahb_read_check(32'h0000_0200, 3'd3);
        ahb_read_check(32'h0000_0208, 3'd3);
        ahb_read_check(32'h0000_020C, 3'd2);
        $display("3 行の上下: 合格");

        // 4: 32 MB の外 (= エラー応答。SDRAM の中身は変わらない)
        addr_phase(32'h0200_0000, 1'b0, 3'd3);
        data_phase(64'd0, 1'b1);
        if (!rd_err) $fatal(1, "32 MB の外の読み出しがエラー応答にならない");
        addr_phase(32'h0200_0200, 1'b1, 3'd3);
        data_phase(64'hDEAD_BEEF_DEAD_BEEF, 1'b1);
        if (!rd_err) $fatal(1, "32 MB の外の書き込みがエラー応答にならない");
        addr_phase(32'h8000_0000, 1'b0, 3'd2);
        data_phase(64'd0, 1'b1);
        if (!rd_err) $fatal(1, "0x8000_0000 の読み出しがエラー応答にならない");
        check_region(32'h0000_0200, 16);   // 下位 25 bit が同じ番地は変わっていない
        $display("4 32 MB の外のエラー応答: 合格");

        // 5: 間を空けずに続ける (= データフェーズの終わりの縁で、次のアドレスフェーズを出す)
        addr_phase(32'h0000_0300, 1'b1, 3'd3);
        hwdata <= 64'hAAAA_0000_BBBB_1111;
        haddr  <= 32'h0000_0308;
        hwrite <= 1'b1;
        hsize  <= 3'd3;
        @(posedge hclk);
        while (!hready) @(posedge hclk);
        hwdata <= 64'hCCCC_2222_DDDD_3333;
        haddr  <= 32'h0000_0300;
        hwrite <= 1'b0;
        hsize  <= 3'd3;
        @(posedge hclk);
        while (!hready) @(posedge hclk);
        htrans <= 2'b00;
        @(posedge hclk);
        #1;
        while (!hready) begin @(posedge hclk); #1; end
        if (hrdata !== 64'hAAAA_0000_BBBB_1111) $fatal(1, "続けた転送の読み出しが %016x", hrdata);
        @(posedge hclk);
        for (i = 0; i < 8; i = i + 1) begin
            shadow_write(32'h0000_0300 + i, pat_byte(64'hAAAA_0000_BBBB_1111, i));
            shadow_write(32'h0000_0308 + i, pat_byte(64'hCCCC_2222_DDDD_3333, i));
        end
        check_region(32'h0000_0300, 16);
        $display("5 間を空けない転送: 合格");

        // 6: 32 MB の一番上
        ahb_write(32'h01FF_FFF8, 3'd3, 64'hFEDC_BA98_7654_3210);
        ahb_write(32'h01FF_FFF0, 3'd1, 64'h0000_0000_0000_BEEF);
        check_region(32'h01FF_FFF0, 16);
        $display("6 32 MB の一番上: 合格");

        // 7: 乱数の番地と HSIZE (= 下の 4 KB と、一番上の 4 KB)
        for (r = 0; r < 300; r = r + 1) begin
            sz  = $unsigned($random(seed)) % 4;
            ad  = ($unsigned($random(seed)) % 4096) & ~((32'd1 << sz) - 1);
            if ($unsigned($random(seed)) % 2 != 0) ad = ad + 32'h01FF_F000;
            pat = {$random(seed), $random(seed)};
            if ($unsigned($random(seed)) % 3 == 0) ahb_read_check(ad, sz[2:0]);
            else                                  ahb_write(ad, sz[2:0], pat);
        end
        check_region(32'h0000_0000, 4096);
        check_region(32'h01FF_F000, 4096);
        $display("7 乱数の読み書き: 合格");

        // 8: 転送を待っている途中のリセット (= SDRAM の中身は残る。リセットの後も読み書きが正しい)
        addr_phase(32'h0000_0400, 1'b1, 3'd3);
        hwdata <= 64'h0102_0304_0506_0708;
        htrans <= 2'b00;
        repeat (3) @(posedge hclk);
        rst_n = 1'b0;
        repeat (3) @(posedge hclk);
        rst_n = 1'b1;
        repeat (20) @(posedge sclk);
        // 書き込みが途中で済んだかは決まらないので、その 8 byte は書き直してから確かめる
        ahb_write(32'h0000_0400, 3'd3, 64'h1112_1314_1516_1718);
        check_region(32'h0000_0400, 8);
        check_region(32'h0000_0000, 256);
        $display("8 途中のリセット: 合格");

        // 9: カウンタ (= 数が決まる転送を出し、前後の差を見る。カウンタを読む転送、カウンタへの書き込み、エラー応答は数えない)
        for (i = 0; i < 7; i = i + 1) stat_read(i, st_before[i]);
        ahb_write(32'h0000_0500, 3'd0, 64'h0000_0000_0000_0011);   // 1 byte
        ahb_write(32'h0000_0504, 3'd2, 64'h2233_4455_0000_0000);   // 4 byte
        ahb_write(32'h0000_0508, 3'd3, 64'h6677_8899_AABB_CCDD);   // 8 byte
        ahb_read_check(32'h0000_0500, 3'd3);
        ahb_read_check(32'h0000_0508, 3'd3);
        addr_phase(STAT_BASE, 1'b1, 3'd2);                            // カウンタへの書き込み (= 何もしない、OKAY)
        data_phase(64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        if (rd_err) $fatal(1, "カウンタへの書き込みがエラー応答");
        addr_phase(STAT_BASE + 32'h20, 1'b0, 3'd2);                  // カウンタの範囲のすぐ外 (= エラー応答)
        data_phase(64'd0, 1'b1);
        if (!rd_err) $fatal(1, "0x%08x (= カウンタの範囲のすぐ外) がエラー応答にならない", STAT_BASE + 32'h20);
        for (i = 0; i < 7; i = i + 1) stat_read(i, st_after[i]);
        if (st_after[0] - st_before[0] != 2)  $fatal(1, "読みの転送の数の差が %0d (= 2 のはず)", st_after[0] - st_before[0]);
        if (st_after[2] - st_before[2] != 3)  $fatal(1, "書きの転送の数の差が %0d (= 3 のはず)", st_after[2] - st_before[2]);
        if (st_after[6] - st_before[6] != 13) $fatal(1, "書いた byte の数の差が %0d (= 1 + 4 + 8 = 13 のはず)", st_after[6] - st_before[6]);
        for (i = 1; i < 6; i = i + 2) begin
            if (st_after[i] == st_before[i]) $fatal(1, "カウンタ +0x%02x (= サイクル数) が増えていない", 4 * i);
        end
        if (st_after[4] == st_before[4]) $fatal(1, "カウンタ +0x10 (= 行の読みの sclk のサイクル数) が増えていない");
        // AE350 を待たせた時間は、SDRAM の制御が動いた時間より長い (= 間にクロックの乗せ換えがある)
        if ((st_after[1] - st_before[1]) * HCLK_PS < (st_after[4] - st_before[4]) * SCLK_PS)
            $fatal(1, "読みで待たせた時間 %0d ps が、行の読みの時間 %0d ps より短い",
                   (st_after[1] - st_before[1]) * HCLK_PS, (st_after[4] - st_before[4]) * SCLK_PS);
        if ((st_after[3] - st_before[3]) * HCLK_PS < (st_after[5] - st_before[5]) * SCLK_PS)
            $fatal(1, "書きで待たせた時間 %0d ps が、書きの時間 %0d ps より短い",
                   (st_after[3] - st_before[3]) * HCLK_PS, (st_after[5] - st_before[5]) * SCLK_PS);
        stat_read(7, st_after[0]);
        if (st_after[0] != 32'd0) $fatal(1, "カウンタ +0x1C が %08x (= 0 のはず)", st_after[0]);
        $display("9 カウンタ: 合格 (= 読み 2 回で待たせた DDR_CLK %0d、行の読みの sclk %0d / 書き 3 回で待たせた DDR_CLK %0d、書きの sclk %0d)",
                 st_after[1] - st_before[1], st_after[4] - st_before[4], st_after[3] - st_before[3], st_after[5] - st_before[5]);

        $display("sdram_tb: 合格 (= 読み出しの確認 %0d 回)", n_checks);
        $finish;
    end

    function [7:0] pat_byte(input [63:0] p, input integer k);
        pat_byte = p[k*8 +: 8];
    endfunction

    // byte 番地を、SDRAM のモデルの中身の番地 (= {バンク, 行, 列}) に直す。sdram_bridge は {行, バンク, 列} で割り振る
    /* verilator lint_off UNUSEDSIGNAL */
    function [31:0] mi(input [31:0] byte_addr);   // 上位と bit 0 は使わない (= 32 MB の 16 bit の語)
    /* verilator lint_on UNUSEDSIGNAL */
        reg [23:0] w;
        begin
            w  = byte_addr[24:1];
            mi = {8'd0, w[10:9], w[23:11], w[8:0]};
        end
    endfunction

endmodule

`default_nettype wire
