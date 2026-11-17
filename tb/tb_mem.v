// =============================================================
// File:        tb/tb_mem.v
// Module:      tb_mem
// Role:        shell_top (AE350_SOC をインスタンス化したトップ) に ROM と DDR のメモリモデルをつなぎ、
//              プログラムを実行するテストベンチ。
//              プログラムは結果を DDR の 0x0000_0000 に 32 ビットで書き込む。テストベンチは DDR_H* でその書き込みを捉え、
//              値を表示して終了する。UART の TXD のビット列は文字に変換し、1 行溜めてから「UART: 」を付けて表示する。
//
// クロック (既定値はリファレンスデザインと同じ。plusarg で半周期を ps 単位で変更できる):
//   CORE_CLK 800 MHz (+core_hp=625)   AHB_CLK 100 MHz (+ahb_hp=5000)   APB_CLK 100 MHz (+apb_hp=5000)
//   DDR_CLK   50 MHz (+ddr_hp=10000)  RTC_CLK  10 MHz (+rtc_hp=50000)
//   ROM のモデルは AHB_CLK、DDR のモデルは DDR_CLK、UART は APB_CLK で動く
//
// Plusargs:
//   +rom=<hex>          ROM の内容 (1 行 1 ワード)
//   +rom_wait=<N>       ROM のウェイトサイクル数 (既定値 0)
//   +ddr_wait=<N>       DDR のウェイトサイクル数 (既定値 0)
//   +max_cycles=<N>     AHB_CLK でこのサイクル数のうちに結果が書き込まれなければ失敗 (既定値 2000000)
//   +core_hp / +ahb_hp / +apb_hp / +ddr_hp / +rtc_hp   各クロックの半周期 (ps)
//   +reset_at=<N>       AHB_CLK の N サイクル目に 1 回だけリセットをかけ、「reset during run」の行を出力する
//   +uart_in=<ファイル>   リセットの後、ファイルの内容を UART の RXD に 1 文字ずつ送る。次の 2 文字は送らずに
//                       制御に使う:
//                         `  プログラムが「READY」で始まる行を UART に出力するまで待つ (N 個目の ` は N 行目の READY を待つ)
//                         ~  次の 1 文字を、ストップビットを 0 にして送る
//   +uart_script=<ファイル>  リセットの後、手順ファイルを 1 行ずつ実行する (ローダーのテストで使う)。
//                       +uart_in とは同時に使えない。行の先頭の 1 文字がコマンドで、空白の後が引数:
//                         S <文字列>     その文字列と改行 (0x0A) を送る
//                         F <ファイル>    ファイルの内容を、変換せずにそのままのバイトで送る
//                         W <文字列>     その文字列で始まる行を、プログラムが UART に出力するまで待つ (まだ照合していない行から
//                                        順に照合する。手順が W に来る前に届いた行も対象にする。照合するのは先頭の 32 文字まで)
//                         P <数>         APB_CLK でその数のサイクルの間、何も送らない
//                         B <文字>       その文字を、ストップビットを 0 にして送る (改行は付けない。受信側は捨てる)
//                         G <数>         以降の S と F で、1 バイト送るたびに APB_CLK でその数のサイクルだけ待つ
//                                        (実機の UART に近い間隔で送るため。既定値 0)
//                         # と空行       何もしない
//
// テストベンチがプログラムに渡す値:
//   0x0000_0008         CORE_CLK と AHB_CLK の周波数比 × 256 (AHB_CLK の周期 × 256 ÷ CORE_CLK の周期)。
//                       リセットの前に DDR のモデルに書き込む (sw/stage4_test.c が mcycle と mtime の比と照合する)
//
// 結果:
//   0x0000_600D         合格 (PASS を表示する)。UART が送信し終わってから、終了コード 0 で終わる (+uart_in の送り残しは見ない)
//   それ以外             失敗した確認の番号 (sw/stage*_test.c)。UART が送信し終わってから $fatal で終わる
//
// バスの形の検査 (違反すれば $fatal):
//   - ROM_HWRITE が 1 にならない
//   - ROM_H*、DDR_H*、APB_P*、EXTS_H* を合わせて、同時に進む転送は 1 つまで (中央バスが 1 つずつ処理する。CORE_CLK ごとに見る)
//   - APB: PENABLE が 1 になるのは、SETUP (PSEL = 1、PENABLE = 0) か、ウェイト中の ACCESS の次のサイクルだけ。
//     SETUP の次は必ず ACCESS。ACCESS の間、PADDR、PWRITE、PWDATA は前のサイクルから変わらない
//   - UART: ストップビットが 1 であること
// =============================================================

`default_nettype none

// 時間の単位は、ビルドのオプションで 1ns / 1ps を与える (Makefile)

module tb_mem;

    localparam [31:0] RESULT_ADDR = 32'h0000_0000;
    localparam [31:0] RESULT_PASS = 32'h0000_600D;

    // UART: 1 ビット = UART_PRESCALE × 8 サイクル (APB_CLK)
    localparam [15:0] UART_PRESCALE  = 16'd2;
    localparam [15:0] UART_BIT_LAST  = UART_PRESCALE * 16'd8 - 16'd1;   // 1 ビットの最後のサイクル
    localparam [15:0] UART_HALF_LAST = UART_PRESCALE * 16'd4 - 16'd1;   // 半ビットの最後のサイクル

    // ---------------------------------------------------------
    // クロックとリセット
    // ---------------------------------------------------------
    integer core_hp, ahb_hp, apb_hp, ddr_hp, rtc_hp;   // 半周期 (ps)
    reg     core_clk, ahb_clk, apb_clk, ddr_clk, rtc_clk;
    reg     rst_n;

    initial begin
        if (!$value$plusargs("core_hp=%d", core_hp)) core_hp = 625;
        if (!$value$plusargs("ahb_hp=%d",  ahb_hp))  ahb_hp  = 5000;
        if (!$value$plusargs("apb_hp=%d",  apb_hp))  apb_hp  = 5000;
        if (!$value$plusargs("ddr_hp=%d",  ddr_hp))  ddr_hp  = 10000;
        if (!$value$plusargs("rtc_hp=%d",  rtc_hp))  rtc_hp  = 50000;
        core_clk = 1'b0;
        ahb_clk  = 1'b0;
        apb_clk  = 1'b0;
        ddr_clk  = 1'b0;
        rtc_clk  = 1'b0;
        rst_n    = 1'b0;
    end

    always #(core_hp / 1000.0) core_clk = ~core_clk;
    always #(ahb_hp  / 1000.0) ahb_clk  = ~ahb_clk;
    always #(apb_hp  / 1000.0) apb_clk  = ~apb_clk;
    always #(ddr_hp  / 1000.0) ddr_clk  = ~ddr_clk;
    always #(rtc_hp  / 1000.0) rtc_clk  = ~rtc_clk;

    wire        uart_tx;
    reg         uart_rx;     // テストベンチが送信する側 (下の「UART の送信」)

    wire [31:0] rom_haddr;
    wire [1:0]  rom_htrans;
    wire        rom_hwrite;
    wire [31:0] rom_hrdata;
    wire        rom_hready;
    wire        rom_hresp;

    wire [31:0] ddr_haddr;
    wire [1:0]  ddr_htrans;
    wire        ddr_hwrite;
    wire [2:0]  ddr_hsize;
    wire [63:0] ddr_hwdata;
    wire [63:0] ddr_hrdata;
    wire        ddr_hready;
    wire        ddr_hresp;

    // ---------------------------------------------------------
    // EXTM_H* のマスタのモデル (FPGA 側のマスタは、テストベンチのモデルで動かす)
    //   +extm_cmd=<ファイル>  手順。1 行に 1 つのコマンド (# から行末までは読まない)
    //     wait                       プログラムが「EXTM」で始まる行を UART に出力するまで待つ (N 個目の wait は N 行目を待つ)
    //     w  <アドレス> <HSIZE> <データ>   書き込む (64 ビットのデータのうち、アドレスと HSIZE で決まるバイトレーンが書き込まれる)
    //     r  <アドレス> <HSIZE> <期待値>   読み出して、アドレスと HSIZE で決まるバイトレーンだけを照合する
    //     re <アドレス> <HSIZE>          読み出して、エラー応答を期待する
    //     we <アドレス> <HSIZE> <データ>   書き込んで、エラー応答を期待する
    //     アドレスとデータは 16 進、HSIZE は 10 進 (0、1、2、3)
    //   +extm_bg=1  手順の合間と wait の間に、DDR の 0x0000_A000〜0x0000_AFFF にランダムに読み書きし、読み出した値を
    //               テストベンチの写しと照合する (CPU と EXTM_H* のアクセスを競合させるため)。乱数の種は +seed に 2 を足したもの
    // 信号はノンブロッキング代入で変える (同じクロックエッジで、DUT が古い値を読むようにする)
    // ---------------------------------------------------------
    reg         extm_hsel;
    reg  [31:0] extm_haddr;
    reg  [1:0]  extm_htrans;
    reg         extm_hwrite;
    reg  [2:0]  extm_hsize;
    reg  [63:0] extm_hwdata;
    wire [63:0] extm_hrdata;
    wire        extm_hreadyout;
    wire        extm_hresp;

    integer     extm_lines;        // 「EXTM」で始まる行を受信した数 (下の「UART の受信」で数える)
    integer     extm_cmds;         // 手順で実行したコマンドの数
    integer     extm_bg_reads;
    integer     extm_bg_writes;

    // 1 回の転送 (アドレスフェーズ → データフェーズ)
    task extm_xfer(input [31:0] a, input w, input [2:0] sz, input [63:0] wd, output [63:0] rd, output err);
        begin
            @(posedge ahb_clk);
            extm_hsel   <= 1'b1;
            extm_htrans <= 2'b10;
            extm_haddr  <= a;
            extm_hwrite <= w;
            extm_hsize  <= sz;
            @(posedge ahb_clk);
            while (!extm_hreadyout) @(posedge ahb_clk);     // このエッジでアドレスフェーズが受け付けられた
            extm_hsel   <= 1'b0;
            extm_htrans <= 2'b00;
            extm_hwdata <= wd;
            @(posedge ahb_clk);
            while (!extm_hreadyout) @(posedge ahb_clk);     // このエッジでデータフェーズが終わった
            rd  = extm_hrdata;
            err = extm_hresp;
        end
    endtask

    // アドレスと HSIZE で決まるバイトレーン (64 ビットのうち、照合するバイトか書き込むバイト)
    function [63:0] lane_mask(input [2:0] a, input [2:0] sz);
        reg [7:0] l;
        integer   k;
        begin
            case (sz)
                3'd0:    l = 8'b0000_0001 << a;
                3'd1:    l = 8'b0000_0011 << {a[2:1], 1'b0};
                3'd2:    l = 8'b0000_1111 << {a[2], 2'b00};
                default: l = 8'b1111_1111;
            endcase
            for (k = 0; k < 8; k = k + 1) lane_mask[k*8 +: 8] = {8{l[k]}};
        end
    endfunction

    // 背景の転送の期待値の写し (0x0000_A000〜0x0000_AFFF の 4 KB。DDR のモデルの初期値と同じ 0xA5 から始める)
    localparam [31:0] BG_BASE = 32'h0000_A000;
    reg     [7:0]  bg_shadow [0:4095];
    integer        bg_seed;
    integer        bg_i;
    reg            extm_bg;

    task extm_bg_op;
        /* verilator lint_off UNUSEDSIGNAL */
        reg [31:0] r;          // 使うのは一部のビットだけ
        /* verilator lint_on UNUSEDSIGNAL */
        reg [2:0]  sz;
        integer    bidx;
        reg [11:0] off;
        reg [63:0] d, rd, m;
        reg        err;
        integer    k;
        begin
            r   = $random(bg_seed);
            sz  = {1'b0, r[1:0]};
            off = r[13:2] & ~((12'd1 << sz) - 12'd1);     // HSIZE の境界に揃える
            bidx = {20'd0, off[11:3], 3'd0};
            d   = {$random(bg_seed), $random(bg_seed)};
            m   = lane_mask(off[2:0], sz);
            if (r[16]) begin
                extm_xfer(BG_BASE + {20'd0, off}, 1'b1, sz, d, rd, err);
                if (err) $fatal(1, "EXTM background: write got an error response (0x%08x)", BG_BASE + {20'd0, off});
                for (k = 0; k < 8; k = k + 1) begin
                    if (m[k*8]) bg_shadow[bidx + k] = d[k*8 +: 8];
                end
                extm_bg_writes = extm_bg_writes + 1;
            end else begin
                extm_xfer(BG_BASE + {20'd0, off}, 1'b0, sz, 64'd0, rd, err);
                if (err) $fatal(1, "EXTM background: read got an error response (0x%08x)", BG_BASE + {20'd0, off});
                for (k = 0; k < 8; k = k + 1) begin
                    if (m[k*8] && rd[k*8 +: 8] !== bg_shadow[bidx + k]) begin
                        $fatal(1, "EXTM background: value %h at 0x%08x differs from the copy %h", BG_BASE + {20'd0, off[11:3], 3'd0} + k,
                               rd[k*8 +: 8], bg_shadow[bidx + k]);
                    end
                end
                extm_bg_reads = extm_bg_reads + 1;
            end
        end
    endtask

    // 手順
    reg [8*256-1:0] extm_path;
    integer         extm_fd;
    integer         extm_n;
    integer         extm_waits;
    reg [8*8-1:0]   tok;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [8*256-1:0] rest;          // 読み捨てる行
    /* verilator lint_on UNUSEDSIGNAL */
    reg [31:0]      ca;
    reg [2:0]       csz;
    reg [63:0]      cd, crd, cm;
    reg             cerr;

    initial begin
        extm_hsel      = 1'b0;
        extm_haddr     = 32'd0;
        extm_htrans    = 2'b00;
        extm_hwrite    = 1'b0;
        extm_hsize     = 3'd0;
        extm_hwdata    = 64'd0;
        extm_cmds      = 0;
        extm_bg_reads  = 0;
        extm_bg_writes = 0;
        extm_waits     = 0;
        extm_bg        = 1'b0;
        if (!$value$plusargs("seed=%d", bg_seed)) bg_seed = 1;
        bg_seed = bg_seed + 2;
        for (bg_i = 0; bg_i < 4096; bg_i = bg_i + 1) bg_shadow[bg_i] = 8'hA5;
        if ($value$plusargs("extm_bg=%d", bg_i)) extm_bg = (bg_i != 0);
        extm_fd = 0;
        if ($value$plusargs("extm_cmd=%s", extm_path)) begin
            extm_fd = $fopen(extm_path, "r");
            if (extm_fd == 0) $fatal(1, "cannot open the +extm_cmd file");
        end
        wait (rst_n);
        repeat (8) @(posedge ahb_clk);
        if (extm_fd != 0) begin
            extm_n = $fscanf(extm_fd, "%s", tok);
            while (extm_n == 1) begin
                if (tok == "#") begin
                    extm_n = $fgets(rest, extm_fd);           // 行末まで読み捨てる
                end else if (tok == "wait") begin
                    extm_waits = extm_waits + 1;
                    while (extm_lines < extm_waits) begin
                        if (extm_bg) extm_bg_op();
                        else         @(posedge ahb_clk);
                    end
                end else if (tok == "w" || tok == "we") begin
                    extm_n = $fscanf(extm_fd, "%h %d %h", ca, csz, cd);
                    extm_xfer(ca, 1'b1, csz, cd, crd, cerr);
                    if (cerr != (tok == "we")) $fatal(1, "EXTM: unexpected response to %0s 0x%08x (error %b)", tok, ca, cerr);
                    extm_cmds = extm_cmds + 1;
                end else if (tok == "r") begin
                    extm_n = $fscanf(extm_fd, "%h %d %h", ca, csz, cd);
                    extm_xfer(ca, 1'b0, csz, 64'd0, crd, cerr);
                    cm = lane_mask(ca[2:0], csz);
                    if (cerr) $fatal(1, "EXTM: r 0x%08x got an error response", ca);
                    if ((crd & cm) !== (cd & cm)) $fatal(1, "EXTM: r 0x%08x returned %h, expected %h", ca, crd & cm, cd & cm);
                    extm_cmds = extm_cmds + 1;
                end else if (tok == "re") begin
                    extm_n = $fscanf(extm_fd, "%h %d", ca, csz);
                    extm_xfer(ca, 1'b0, csz, 64'd0, crd, cerr);
                    if (!cerr) $fatal(1, "EXTM: re 0x%08x did not get an error response", ca);
                    extm_cmds = extm_cmds + 1;
                end else begin
                    $fatal(1, "EXTM: unknown command %0s", tok);
                end
                if (extm_bg) extm_bg_op();
                extm_n = $fscanf(extm_fd, "%s", tok);
            end
            $fclose(extm_fd);
        end
        // 手順が終わった後も、プログラムが終わるまで背景の転送を続ける
        while (extm_bg) extm_bg_op();
    end

    /* verilator lint_off PINCONNECTEMPTY */
    shell_top #(
        .UART_PRESCALE (UART_PRESCALE),
        .EXTS_WAIT     (1)               // EXTS_H* の先の RAM の、ウェイトありの経路を通す
    ) u_top (
        .core_clk   (core_clk),
        .ahb_clk    (ahb_clk),
        .apb_clk    (apb_clk),
        .ddr_clk    (ddr_clk),
        .rtc_clk    (rtc_clk),
        .rst_n      (rst_n),
        .uart_tx    (uart_tx),
        .uart_rx    (uart_rx),
        .hresetn    (),
        .dbg_presetn    (),
        .dbg_apb_access (),
        .dbg_apb_paddr  (),
        .dbg_misc       (),
        .rom_haddr  (rom_haddr),
        .rom_htrans (rom_htrans),
        .rom_hwrite (rom_hwrite),
        .rom_hrdata (rom_hrdata),
        .rom_hready (rom_hready),
        .rom_hresp  (rom_hresp),
        .ddr_haddr  (ddr_haddr),
        .ddr_htrans (ddr_htrans),
        .ddr_hwrite (ddr_hwrite),
        .ddr_hsize  (ddr_hsize),
        .ddr_hwdata (ddr_hwdata),
        .ddr_hrdata (ddr_hrdata),
        .ddr_hready (ddr_hready),
        .ddr_hresp  (ddr_hresp),
        .extm_hsel      (extm_hsel),
        .extm_haddr     (extm_haddr),
        .extm_htrans    (extm_htrans),
        .extm_hburst    (3'b000),
        .extm_hwrite    (extm_hwrite),
        .extm_hsize     (extm_hsize),
        .extm_hprot     (4'b0011),
        .extm_hwdata    (extm_hwdata),
        .extm_hrdata    (extm_hrdata),
        .extm_hreadyout (extm_hreadyout),
        .extm_hresp     (extm_hresp)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    ahb_rom_model u_rom (
        .clk    (ahb_clk),
        .rst_n  (rst_n),
        .haddr  (rom_haddr),
        .htrans (rom_htrans),
        .hrdata (rom_hrdata),
        .hready (rom_hready),
        .hresp  (rom_hresp)
    );

    `ifdef TB_SDRAM
    // DDR_H* の先を、実機と同じ SDRAM の経路にする (ahb_sdram → sdram_bridge → SDRAM のモデル)。
    // SDRAM のクロックは +sdram_hp (半周期 ps。既定値は 25000 で 20 MHz、SDRAM_HS では 3000 で 166.7 MHz)。ピンには反転して出す
    integer sdram_hp;
    reg     sdram_clk;
    initial begin
`ifdef SDRAM_HS
        if (!$value$plusargs("sdram_hp=%d", sdram_hp)) sdram_hp = 3000;      // 166.7 MHz 版の既定値 (周期 6 ns)
`else
        if (!$value$plusargs("sdram_hp=%d", sdram_hp)) sdram_hp = 25000;
`endif
        sdram_clk = 1'b0;
    end
    always #(sdram_hp / 1000.0) sdram_clk = ~sdram_clk;


    // SDRAM 側のリセット。ahb_sdram は非同期、sdram_bridge は同期でリセットを受ける
    /* verilator lint_off SYNCASYNCNET */
    reg [1:0] srst_s;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge sdram_clk or negedge rst_n) begin
        if (!rst_n) srst_s <= 2'b00;
        else        srst_s <= {srst_s[0], 1'b1};
    end
    wire srst_n = srst_s[1];

    wire          s_fill_valid, s_fill_ready, s_we, s_wready, s_init_done;
    wire [20:0]   s_fill_line;
    wire [127:0]  s_fill_data;
    wire [24:0]   s_waddr;
    wire [7:0]    s_wdata;

    ahb_sdram #(.SDRAM_AW(25)) u_ahb_sdram (
        .hclk       (ddr_clk),
        .hresetn    (rst_n),
        .haddr      (ddr_haddr),
        .htrans     (ddr_htrans),
        .hwrite     (ddr_hwrite),
        .hsize      (ddr_hsize),
        .hwdata     (ddr_hwdata),
        .hrdata     (ddr_hrdata),
        .hreadyout  (ddr_hready),
        .hresp      (ddr_hresp),
        .sclk       (sdram_clk),
        .srst_n     (srst_n),
        .fill_valid (s_fill_valid),
        .fill_line  (s_fill_line),
        .fill_ready (s_fill_ready),
        .fill_data  (s_fill_data),
        .we         (s_we),
        .waddr      (s_waddr),
        .wdata      (s_wdata),
        .wready     (s_wready)
    );

`ifdef SDRAM_HS
    // 166.7 MHz 版の経路 (sdram_ctrl_hs → sdram_io → SDRAM のモデル。tb/sdram_hs_path.v)
    sdram_hs_path #(.ADDR_WIDTH(25), .RD_FIRST(11), .IN_DLY(160), .CAP_EDGE(0)) u_path (
        .s_clk (sdram_clk), .rst_n (srst_n), .fill_valid (s_fill_valid), .fill_line (s_fill_line),
        .fill_ready (s_fill_ready), .fill_data (s_fill_data), .we (s_we), .waddr (s_waddr), .wdata (s_wdata),
        .wready (s_wready), .init_done (s_init_done)
    );
    `define TB_SDRAM_MEM u_path.u_model.mem
`else
    `define TB_SDRAM_MEM u_sdram.mem
    wire [15:0]   sdram_dq;
    wire [12:0]   sdram_a;
    wire [1:0]    sdram_ba, sdram_dqm;
    wire          sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;

    sdram_bridge #(.ADDR_WIDTH(25)) u_sdram_bridge (
        .clk         (sdram_clk),
        .rst_n       (srst_n),
        .fill_valid  (s_fill_valid),
        .fill_line   (s_fill_line),
        .fill_ready  (s_fill_ready),
        .fill_data   (s_fill_data),
        .we          (s_we),
        .waddr       (s_waddr),
        .wdata       (s_wdata),
        .wready      (s_wready),
        .init_done   (s_init_done),
        .sdram_dq    (sdram_dq),
        .sdram_addr  (sdram_a),
        .sdram_ba    (sdram_ba),
        .sdram_cs_n  (sdram_cs_n),
        .sdram_ras_n (sdram_ras_n),
        .sdram_cas_n (sdram_cas_n),
        .sdram_we_n  (sdram_we_n),
        .sdram_dqm   (sdram_dqm)
    );

    sdram_model u_sdram (
        .clk (~sdram_clk), .cke (1'b1), .csn (sdram_cs_n), .rasn (sdram_ras_n), .casn (sdram_cas_n), .wen (sdram_we_n),
        .dqm (sdram_dqm), .ba (sdram_ba), .addr (sdram_a), .dq (sdram_dq)
    );
`endif

    // バイトアドレスの 16 ビットワードを、モデルの内容のアドレス ({バンク, 行, 列}) に変換する。sdram_bridge は {行, バンク, 列} で割り当てる
    /* verilator lint_off UNUSEDSIGNAL */
    function [31:0] sdram_idx(input [31:0] byte_addr);   // 上位とビット 0 は使わない (32 MB の 16 ビットワード)
    /* verilator lint_on UNUSEDSIGNAL */
        reg [23:0] w;
        begin
            w         = byte_addr[24:1];
            sdram_idx = {8'd0, w[10:9], w[23:11], w[8:0]};
        end
    endfunction

    // テストベンチから 32 ビットを書き込む (16 ビットワード 2 つ)
    task ddr_poke32(input [31:0] a, input [31:0] v);
        begin
            `TB_SDRAM_MEM[sdram_idx(a)]      = v[15:0];
            `TB_SDRAM_MEM[sdram_idx(a + 2)]  = v[31:16];
        end
    endtask

    // DDR のモデルと同じく、プログラムが使う下位 64 KB を 0xA5 で初期化する (EXTM_H* の背景の転送がこれを前提にしている)
    integer sdram_i;
    initial begin
        for (sdram_i = 0; sdram_i < 65536; sdram_i = sdram_i + 2) `TB_SDRAM_MEM[sdram_idx(sdram_i)] = 16'hA5A5;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_sdram = s_init_done;
    /* verilator lint_on UNUSEDSIGNAL */
    `else
    ahb_ddr_model u_ddr (
        .clk    (ddr_clk),
        .rst_n  (rst_n),
        .haddr  (ddr_haddr),
        .htrans (ddr_htrans),
        .hwrite (ddr_hwrite),
        .hsize  (ddr_hsize),
        .hwdata (ddr_hwdata),
        .hrdata (ddr_hrdata),
        .hready (ddr_hready),
        .hresp  (ddr_hresp)
    );

    // テストベンチから 32 ビットを書き込む
    /* verilator lint_off UNUSEDSIGNAL */
    task ddr_poke32(input [31:0] a, input [31:0] v);   // 4 バイト境界のアドレス (モデルは 64 KB)
    /* verilator lint_on UNUSEDSIGNAL */
        begin
            if (a[2]) u_ddr.mem[a[15:3]][63:32] = v;
            else      u_ddr.mem[a[15:3]][31:0]  = v;
        end
    endtask
    `endif

    // APB_P* は shell_top の中の配線を見る
    wire        apb_psel    = u_top.apb_psel;
    wire        apb_penable = u_top.apb_penable;
    wire        apb_pready  = u_top.apb_pready;
    wire        apb_pwrite  = u_top.apb_pwrite;
    wire [31:0] apb_paddr   = u_top.apb_paddr;
    wire [31:0] apb_pwdata  = u_top.apb_pwdata;

    // UART の送信回路に、まだ送っていない文字があるか
    wire        uart_pending = u_top.u_uart.hold_valid || u_top.u_uart.tx_busy;

    // ---------------------------------------------------------
    // リセット: プログラムに渡す値を DDR のモデルに書き込んでから解除する
    // ---------------------------------------------------------
    integer max_cycles;
    integer reset_at;
    integer cycles;         // AHB_CLK のサイクル数 (下の「AHB_CLK」で数える)

    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
        repeat (4) @(posedge ahb_clk);
        ddr_poke32(32'h0000_0008, (ahb_hp * 256) / core_hp);
        repeat (2) @(posedge ahb_clk);
        rst_n = 1'b1;
        // +reset_at=<N>: AHB_CLK の N サイクル目に 1 回だけリセットをかける (動作途中のリセット)。
        // DDR のモデルの内容はそのまま残る (本物の DRAM と同じ)
        if ($value$plusargs("reset_at=%d", reset_at)) begin
            wait (cycles == reset_at);
            $display("reset during run (AHB_CLK cycle %0d)", reset_at);
            rst_n = 1'b0;
            repeat (4) @(posedge ahb_clk);
            rst_n = 1'b1;
        end
    end

    // ---------------------------------------------------------
    // UART の受信の状態と、受信した行 (下の「UART の受信」)
    // ---------------------------------------------------------
    localparam [1:0] RX_IDLE  = 2'd0;
    localparam [1:0] RX_START = 2'd1;   // スタートビットの中央を待つ
    localparam [1:0] RX_DATA  = 2'd2;
    localparam [1:0] RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [15:0] rx_count;
    reg [3:0]  rx_bit;
    reg [7:0]  rx_shift;

    // 受信した文字は 1 行分溜めて、改行で「UART: 」を付けて表示する (結果の表示と混ざらないように)
    localparam integer RX_LINE_MAX = 256;
    reg [7:0]  rx_line [0:RX_LINE_MAX-1];
    integer    rx_len;
    integer    rx_i;

    localparam integer HIST_LINES = 4096;
    localparam integer HIST_W     = 32;
    reg [8*HIST_W-1:0] hist [0:HIST_LINES-1];   // 受信した行の先頭 32 文字 (k 文字目は [8*k +: 8])
    integer            lines_done;               // 受信し終わった行の数

    // 受信し終わった行の先頭 32 文字を、+uart_script の W のために保持する
    task save_rx_line;
        reg [8*32-1:0] h;
        begin
            h = 0;
            for (rx_i = 0; rx_i < rx_len && rx_i < 32; rx_i = rx_i + 1) h[8 * rx_i +: 8] = rx_line[rx_i];
            if (lines_done < 4096) hist[lines_done] = h;
            lines_done = lines_done + 1;
        end
    endtask

    task print_rx_line;
        begin
            $write("UART: ");
            for (rx_i = 0; rx_i < rx_len; rx_i = rx_i + 1) $write("%c", rx_line[rx_i]);
            $write("\n");
        end
    endtask

    // 「READY」で始まる行を受信した数 (+uart_in の ` が待つ)
    integer ready_lines;
    wire    rx_line_is_ready = (rx_len >= 5) &&
                               rx_line[0] == 8'h52 && rx_line[1] == 8'h45 && rx_line[2] == 8'h41 &&
                               rx_line[3] == 8'h44 && rx_line[4] == 8'h59;   // "READY"
    wire    rx_line_is_extm  = (rx_len >= 4) &&
                               rx_line[0] == 8'h45 && rx_line[1] == 8'h58 && rx_line[2] == 8'h54 &&
                               rx_line[3] == 8'h4D;                               // "EXTM"

    // ---------------------------------------------------------
    // UART の送信: +uart_in のファイルの内容を RXD に送る (8 ビット、パリティなし、ストップビット 1、APB_CLK)
    // ---------------------------------------------------------
    localparam [7:0]   IN_WAIT_READY = 8'h60;   // `
    localparam [7:0]   IN_BAD_STOP   = 8'h7E;   // ~
    localparam integer IN_MAX        = 4096;

    reg [7:0]       in_buf [0:IN_MAX-1];
    integer         in_len;
    integer         in_fd;
    integer         in_c;
    integer         in_i;
    integer         in_waits;
    reg             in_bad_stop;
    reg [8*256-1:0] in_path;

    task send_bit(input b);
        begin
            uart_rx = b;
            repeat (UART_PRESCALE * 8) @(posedge apb_clk);
        end
    endtask

    task send_byte(input [7:0] data, input bad_stop);
        integer k;
        begin
            send_bit(1'b0);
            for (k = 0; k < 8; k = k + 1) send_bit(data[k]);
            send_bit(!bad_stop);
            uart_rx = 1'b1;
        end
    endtask

    initial begin
        uart_rx     = 1'b1;
        in_len      = 0;
        in_waits    = 0;
        in_bad_stop = 1'b0;
        if ($value$plusargs("uart_in=%s", in_path)) begin
            in_fd = $fopen(in_path, "rb");
            if (in_fd == 0) $fatal(1, "cannot open the +uart_in file");
            in_c = $fgetc(in_fd);
            while (in_c != -1) begin
                if (in_len >= IN_MAX) $fatal(1, "the +uart_in file exceeds %0d bytes", IN_MAX);
                in_buf[in_len] = in_c[7:0];
                in_len         = in_len + 1;
                in_c           = $fgetc(in_fd);
            end
            $fclose(in_fd);
        end
        wait (rst_n);
        for (in_i = 0; in_i < in_len; in_i = in_i + 1) begin
            if (in_buf[in_i] == IN_WAIT_READY) begin
                in_waits = in_waits + 1;
                wait (ready_lines >= in_waits);
            end else if (in_buf[in_i] == IN_BAD_STOP) begin
                in_bad_stop = 1'b1;
            end else begin
                send_byte(in_buf[in_i], in_bad_stop);
                in_bad_stop = 1'b0;
            end
        end
    end

    // ---------------------------------------------------------
    // UART の送信: +uart_script の手順 (S、F、W、P、G、B)
    // ---------------------------------------------------------

    reg [8*256-1:0] sc_line;
    reg [8*256-1:0] sc_arg;      // 引数 (右詰めの文字列。$fopen にそのまま渡せる)
    reg [8*256-1:0] sc_path;
    integer         sc_fd, sc_n, sc_len, sc_k, sc_pos, sc_cyc, sc_hit, sc_ffd, sc_c, sc_gap;
    reg [7:0]       sc_cmd;

    // 引数の k 文字目 (0 始まり)
    function [7:0] sc_ch(input integer k);
        sc_ch = sc_arg[8 * (sc_len - 1 - k) +: 8];
    endfunction

    initial begin
        lines_done = 0;
        if ($value$plusargs("uart_script=%s", sc_path)) begin
            if ($test$plusargs("uart_in")) $fatal(1, "+uart_script and +uart_in cannot be used together");
            sc_fd = $fopen(sc_path, "r");
            if (sc_fd == 0) $fatal(1, "cannot open the +uart_script file");
            sc_pos = 0;
            sc_gap = 0;
            wait (rst_n);
            sc_n = $fgets(sc_line, sc_fd);
            while (sc_n > 0) begin
                // 行末の改行を除き、先頭の 2 文字 (コマンドと空白) を除いた引数を取り出す
                if (sc_line[7:0] == 8'h0A) begin
                    sc_line = sc_line >> 8;
                    sc_n    = sc_n - 1;
                end
                sc_cmd = (sc_n > 0) ? sc_line[8 * (sc_n - 1) +: 8] : 8'h23;
                sc_len = (sc_n > 2) ? sc_n - 2 : 0;
                sc_arg = 0;
                for (sc_k = 0; sc_k < sc_len; sc_k = sc_k + 1) sc_arg[8 * sc_k +: 8] = sc_line[8 * sc_k +: 8];
                case (sc_cmd)
                    8'h53: begin   // S
                        for (sc_k = 0; sc_k < sc_len; sc_k = sc_k + 1) begin
                            send_byte(sc_ch(sc_k), 1'b0);
                            repeat (sc_gap) @(posedge apb_clk);
                        end
                        send_byte(8'h0A, 1'b0);
                        repeat (sc_gap) @(posedge apb_clk);
                    end
                    8'h46: begin   // F
                        sc_ffd = $fopen(sc_arg, "rb");
                        if (sc_ffd == 0) $fatal(1, "cannot open the file for F in +uart_script");
                        sc_c = $fgetc(sc_ffd);
                        while (sc_c != -1) begin
                            send_byte(sc_c[7:0], 1'b0);
                            repeat (sc_gap) @(posedge apb_clk);
                            sc_c = $fgetc(sc_ffd);
                        end
                        $fclose(sc_ffd);
                    end
                    8'h57: begin   // W
                        if (sc_len > HIST_W) $fatal(1, "the W string in +uart_script exceeds %0d characters", HIST_W);
                        sc_hit = 0;
                        while (sc_hit == 0) begin
                            wait (lines_done > sc_pos);
                            if (sc_pos >= HIST_LINES) $fatal(1, "UART output exceeds %0d lines", HIST_LINES);
                            sc_hit = 1;
                            for (sc_k = 0; sc_k < sc_len; sc_k = sc_k + 1)
                                if (hist[sc_pos][8 * sc_k +: 8] != sc_ch(sc_k)) sc_hit = 0;
                            sc_pos = sc_pos + 1;
                        end
                    end
                    8'h42: begin   // B
                        for (sc_k = 0; sc_k < sc_len; sc_k = sc_k + 1) begin
                            send_byte(sc_ch(sc_k), 1'b1);
                            repeat (sc_gap) @(posedge apb_clk);
                        end
                    end
                    8'h47: begin   // G
                        if ($sscanf(sc_arg, "%d", sc_gap) != 1) $fatal(1, "cannot parse the number for G in +uart_script");
                    end
                    8'h50: begin   // P
                        if ($sscanf(sc_arg, "%d", sc_cyc) != 1) $fatal(1, "cannot parse the number for P in +uart_script");
                        repeat (sc_cyc) @(posedge apb_clk);
                    end
                    8'h23: ;       // # (何もしない)
                    default: $fatal(1, "unknown command %c in +uart_script", sc_cmd);
                endcase
                sc_n = $fgets(sc_line, sc_fd);
            end
            $fclose(sc_fd);
        end
    end

    // ---------------------------------------------------------
    // AHB_CLK: ROM_H* を監視し、サイクル数を数える
    // ---------------------------------------------------------
    integer rom_reads;
    integer apb_reads;      // APB_CLK 側で数える
    integer apb_writes;
    reg     rom_dph;
    wire    rom_accept = rom_htrans[1] && rom_hready;
    wire    rom_busy   = rom_htrans[1] || rom_dph;    // 転送の途中 (アドレスフェーズかデータフェーズ)

    // EXTS_H* (AHB_CLK) は shell_top の中の配線を見る
    wire [1:0]  exts_htrans = u_top.exts_htrans;
    wire        exts_hready = u_top.exts_hreadyout;
    wire        exts_accept = exts_htrans[1] && u_top.exts_hsel && exts_hready;
    reg         exts_dph;
    wire        exts_busy   = exts_htrans[1] || exts_dph;

    always @(posedge ahb_clk or negedge rst_n) begin
        if (!rst_n) begin
            cycles    <= 0;
            rom_reads <= 0;
            rom_dph   <= 1'b0;
            exts_dph  <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            exts_dph <= exts_accept || (exts_dph && !exts_hready);
            if (rom_accept) rom_reads <= rom_reads + 1;
            rom_dph <= rom_accept || (rom_dph && !rom_hready);
            if (rom_hwrite) begin
                $fatal(1, "ROM_HWRITE became 1 (cycle %0d)", cycles);
            end
            if (cycles >= max_cycles) begin
                $fatal(1, "did not finish within %0d cycles", max_cycles);
            end
        end
    end

    // ---------------------------------------------------------
    // DDR_CLK: DDR_H* を監視し、結果の書き込みを捉える
    // ---------------------------------------------------------
    integer    ddr_reads;
    integer    ddr_writes;
    reg        ddr_dph;
    reg        result_dph;     // 結果のアドレスへの 32 ビットの書き込みのデータフェーズ
    reg        finished;       // 結果が書き込まれた (UART が送信し終わるのを待っている)
    reg [31:0] result_code;
    wire       ddr_accept = ddr_htrans[1] && ddr_hready;
    wire       ddr_busy   = ddr_htrans[1] || ddr_dph;

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr_reads   <= 0;
            ddr_writes  <= 0;
            ddr_dph     <= 1'b0;
            result_dph  <= 1'b0;
            finished    <= 1'b0;
            result_code <= 32'd0;
        end else begin
            if (ddr_accept) begin
                if (ddr_hwrite) ddr_writes <= ddr_writes + 1;
                else            ddr_reads  <= ddr_reads + 1;
            end
            ddr_dph <= ddr_accept || (ddr_dph && !ddr_hready);
            // CPU のスタックが、EXTM_H* の背景の転送の範囲 (0x0000_A000〜0x0000_AFFF) まで伸びていない
            if (extm_bg && ddr_accept && ddr_hwrite && ddr_haddr[31:12] == 20'h0000A && !u_top.u_ae350.u_fabric.b_extm) begin
                $fatal(1, "CPU wrote to the EXTM_H* background range (0x%08x) (the stack grew into this range; nested exceptions can also cause this)", ddr_haddr);
            end
            if (ddr_hready) begin
                if (result_dph) begin
                    $display("result 0x%08x (AHB_CLK %0d cycles, ROM reads %0d, DDR reads %0d, DDR writes %0d, APB reads %0d, APB writes %0d)",
                             ddr_hwdata[31:0], cycles, rom_reads, ddr_reads, ddr_writes, apb_reads, apb_writes);
                    finished    <= 1'b1;
                    result_code <= ddr_hwdata[31:0];
                end
                result_dph <= ddr_htrans[1] && ddr_hwrite && ddr_hsize == 3'd2 && ddr_haddr == RESULT_ADDR;
            end
        end
    end

    // ---------------------------------------------------------
    // APB_CLK: APB_P* の形を検査し、終了のタイミングを決める
    // ---------------------------------------------------------
    reg        apb_prev_setup;     // SETUP だった
    reg        apb_prev_wait;      // ウェイト中の ACCESS だった
    reg [31:0] apb_prev_paddr;
    reg        apb_prev_pwrite;
    reg [31:0] apb_prev_pwdata;

    wire apb_setup  = apb_psel && !apb_penable;
    wire apb_access = apb_psel &&  apb_penable;

    always @(posedge apb_clk or negedge rst_n) begin
        if (!rst_n) begin
            apb_reads       <= 0;
            apb_writes      <= 0;
            apb_prev_setup  <= 1'b0;
            apb_prev_wait   <= 1'b0;
            apb_prev_paddr  <= 32'd0;
            apb_prev_pwrite <= 1'b0;
            apb_prev_pwdata <= 32'd0;
        end else begin
            if (apb_setup) begin
                if (apb_pwrite) apb_writes <= apb_writes + 1;
                else            apb_reads  <= apb_reads + 1;
            end

            if (apb_penable && !apb_psel) begin
                $fatal(1, "APB: PENABLE = 1 while PSEL = 0");
            end
            if (apb_access && !(apb_prev_setup || apb_prev_wait)) begin
                $fatal(1, "APB: entered ACCESS without SETUP");
            end
            if (apb_prev_setup && !apb_access) begin
                $fatal(1, "APB: SETUP was not followed by ACCESS");
            end
            if (apb_prev_wait && !apb_access) begin
                $fatal(1, "APB: ACCESS was abandoned while waiting for PREADY");
            end
            if (apb_access && (apb_paddr != apb_prev_paddr || apb_pwrite != apb_prev_pwrite ||
                               (apb_pwrite && apb_pwdata != apb_prev_pwdata))) begin
                $fatal(1, "APB: PADDR, PWRITE, or PWDATA changed during ACCESS");
            end
            apb_prev_setup  <= apb_setup;
            apb_prev_wait   <= apb_access && !apb_pready;
            apb_prev_paddr  <= apb_paddr;
            apb_prev_pwrite <= apb_pwrite;
            apb_prev_pwdata <= apb_pwdata;

            // 結果が書き込まれた後、UART が送信し終わり、受信側も 1 文字を受信し終わってから止める
            // (失敗したときも、プログラムが直前に出力した行を残すため)
            if (finished && !uart_pending && rx_state == RX_IDLE) begin
                if (rx_len != 0) $display("UART: (%0d characters without a trailing newline not shown)", rx_len);
                if (result_code == RESULT_PASS) begin
                    if (extm_cmds != 0 || extm_bg)
                        $display("EXTM: %0d commands, background reads %0d / writes %0d", extm_cmds, extm_bg_reads, extm_bg_writes);
                    $display("PASS");
                    $finish;
                end else begin
                    $fatal(1, "FAIL: check %0d", result_code);
                end
            end
        end
    end

    // ---------------------------------------------------------
    // 不定値 (X、Z) の検査: 4 値のシミュレータ (iverilog) で効く。Verilator は 0 と 1 だけで動かすので、常に通る
    //   - 各ポートの HTRANS と PSEL、転送途中のアドレス、方向、サイズ
    //   - UART の TXD、PLMT と PLIC からの割り込み
    // 書き込みデータは見ない。Hazard3 はレジスタファイルをリセットしないので、プログラムが一度も書き込んでいない
    // レジスタを退避すると (例外の入口の trap_entry)、データが不定値になる。本物の CPU でも内容の決まっていない値を
    // 書き込むだけで、バスの誤りではない。データが壊れていれば、テストプログラムの値の比較で見つかる
    // ---------------------------------------------------------

    always @(posedge ahb_clk) begin
        if (rst_n) begin
            if ((^rom_htrans) === 1'bx) $fatal(1, "unknown value: ROM_HTRANS");
            if (rom_htrans[1] && (^rom_haddr) === 1'bx) $fatal(1, "unknown value: ROM_HADDR");
            if ((^{exts_htrans, u_top.exts_hsel}) === 1'bx) $fatal(1, "unknown value: EXTS_HTRANS / HSEL");
            if (exts_htrans[1] && (^{u_top.exts_haddr, u_top.exts_hwrite, u_top.exts_hsize}) === 1'bx) $fatal(1, "unknown value: EXTS_HADDR / HWRITE / HSIZE");
            if ((^{u_top.u_ae350.mtip, u_top.u_ae350.meip}) === 1'bx) $fatal(1, "unknown value: PLMT / PLIC interrupt");
        end
    end

    always @(posedge ddr_clk) begin
        if (rst_n) begin
            if ((^ddr_htrans) === 1'bx) $fatal(1, "unknown value: DDR_HTRANS");
            if (ddr_htrans[1] && (^{ddr_haddr, ddr_hwrite, ddr_hsize}) === 1'bx) $fatal(1, "unknown value: DDR_HADDR / HWRITE / HSIZE");
        end
    end

    always @(posedge apb_clk) begin
        if (rst_n) begin
            if ((^{apb_psel, uart_tx}) === 1'bx) $fatal(1, "unknown value: APB_PSEL / UART TXD");
            if (apb_psel && (^{apb_paddr, apb_pwrite, apb_penable}) === 1'bx) $fatal(1, "unknown value: APB_PADDR / PWRITE / PENABLE");
        end
    end

    // ---------------------------------------------------------
    // CORE_CLK: 3 つのポートの転送は同時に 1 つまで (CPU のバスは 1 本)
    // ---------------------------------------------------------
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            // 何もしない
        end else if ({2'b0, rom_busy} + {2'b0, ddr_busy} + {2'b0, apb_psel} + {2'b0, exts_busy} > 3'd1) begin
            $fatal(1, "two or more of ROM_H*, DDR_H*, APB_P*, and EXTS_H* are mid-transfer at the same time (ROM %b, DDR %b, APB %b, EXTS %b)",
                   rom_busy, ddr_busy, apb_psel, exts_busy);
        end
    end

    // ---------------------------------------------------------
    // UART の受信: TXD のビット列を文字に変換する (8 ビット、パリティなし、ストップビット 1、APB_CLK)
    // ---------------------------------------------------------
    always @(posedge apb_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state    <= RX_IDLE;
            rx_count    <= 16'd0;
            rx_bit      <= 4'd0;
            rx_shift    <= 8'd0;
            rx_len      <= 0;
            ready_lines <= 0;
            extm_lines  <= 0;
        end else begin
            case (rx_state)
                RX_IDLE: begin
                    if (!uart_tx) begin
                        rx_state <= RX_START;
                        rx_count <= UART_HALF_LAST;
                    end
                end
                RX_START: begin
                    if (rx_count != 16'd0) begin
                        rx_count <= rx_count - 16'd1;
                    end else if (uart_tx) begin
                        $fatal(1, "UART: start bit returned to 1 midway");
                    end else begin
                        rx_state <= RX_DATA;
                        rx_count <= UART_BIT_LAST;
                        rx_bit   <= 4'd0;
                    end
                end
                RX_DATA: begin
                    if (rx_count != 16'd0) begin
                        rx_count <= rx_count - 16'd1;
                    end else begin
                        rx_shift <= {uart_tx, rx_shift[7:1]};
                        rx_count <= UART_BIT_LAST;
                        if (rx_bit == 4'd7) rx_state <= RX_STOP;
                        rx_bit <= rx_bit + 4'd1;
                    end
                end
                default: begin   // RX_STOP
                    if (rx_count != 16'd0) begin
                        rx_count <= rx_count - 16'd1;
                    end else if (!uart_tx) begin
                        $fatal(1, "UART: stop bit is 0");
                    end else begin
                        rx_state <= RX_IDLE;
                        if (rx_shift == 8'h0A) begin
                            print_rx_line();
                            save_rx_line();
                            if (rx_line_is_ready) ready_lines <= ready_lines + 1;
                            if (rx_line_is_extm)  extm_lines  <= extm_lines + 1;
                            rx_len <= 0;
                        end else if (rx_len < RX_LINE_MAX) begin
                            rx_line[rx_len] <= rx_shift;
                            rx_len          <= rx_len + 1;
                        end else begin
                            $fatal(1, "UART: a line exceeds %0d characters", RX_LINE_MAX);
                        end
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
