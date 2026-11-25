// =============================================================
// File:        tb/fb_display_tb.sv
// Module:      fb_display_tb
// Role:        表示の回路 (rtl/fb_display.v) のテストベンチ。hdmi.sv (座標を作る)、fb_display、SDRAM の版の読み出しの回路
//              (rtl/fb_sdram_reader.v)、sdram_ctrl_hs と SDRAM のモデル (tb/sdram_hs_path.v) をつなぎ、hdmi.sv に入る色 (rgb) を
//              画素ごとに期待値と比べる。期待と違えば $fatal で止まる。
//
//   色の時期: hdmi.sv は cx の画素の色を次のクロックで受け取る (カラーバー rtl/hdmi_test_pattern.v と同じ。その時期は
//   make test-hdmi が TMDS を復号して確かめている)。そこで、各クロックで 1 つ前の座標 (表示期間の中) の色として rgb を比べる。
//   カラーバーのラインは、このテストベンチの hdmi_test_pattern の出力とクロックごとに一致することを見る
//
//   フレームバッファ A (0x01C0_0000) と B (0x0100_0000) に、アドレスから決まる模様を SDRAM のモデルに直接置く
//   フレーム 1  ENABLE 0。全画素がカラーバー。レジスタのリセット後の値、FB_BASE の下位 4 ビットが 0 に固定されること
//   フレーム 2  ENABLE 1 (FB_BASE = A)。全 720 ラインの全画素が A
//   フレーム 3  ライン 360 で FB_BASE = B を書く。このフレームは最後まで A
//   フレーム 4  全画素が B。FRAME がフレームごとに 1 増える。ここまで UNDERRUN が 0
//   フレーム 5  ライン 100 の要求だけを、テストベンチが 18 µs 遅らせる。ライン 100 だけカラーバーで、ライン 101 からは B に
//               戻る。UNDERRUN が 1 になり、1 を書くと 0 に戻る
//   フレーム 6  ENABLE 0。全画素がカラーバーで、読み出しの要求が出ない
//   フレーム 7  全画素がカラーバー。CTRL に 1 を書く (CTRL と FB_BASE の書き込みが 6 回目で、書いたことを知らせるトグルが 0 に戻る)
//   フレーム 8  全画素が B。ライン 300 で、表示用の読み出しの最中に、CPU のリセット (PRESETN) だけをかける (ROM のローダーの
//               リセットシーケンスと同じ。画素クロックと SDRAM のクロックの元のリセットはかけない)。リセットの後のこのフレームは比べない
//   フレーム 9  全画素がカラーバーで、読み出しの要求が出ない。レジスタはリセットの後の値 (STATUS は 0、FRAME はリセットの後のフレーム 8 のライン 720 で増えた 1)。CTRL に 1 を書く
//   フレーム 10 全画素が A。UNDERRUN が 0 (読み出しの最中のリセットの後も、正しく読み込める)
//
// 実行: make test-fb-display
// =============================================================

`timescale 1ns/1ps
`default_nettype none

module fb_display_tb;
    localparam int H_ACTIVE = 1280;
    localparam int V_ACTIVE = 720;
    localparam int STRIDE   = 2560;
    localparam logic [24:0] FB_A = 25'h1C0_0000;
    localparam logic [24:0] FB_B = 25'h100_0000;

    // ---------------------------------------------------------
    // クロックとリセット
    // ---------------------------------------------------------
    logic vclk, sclk, pclk, rst_n, cpu_rst_n;   // cpu_rst_n: CPU のリセット (PRESETN だけにかかる)
    initial begin
        vclk = 1'b0; sclk = 1'b0; pclk = 1'b0; rst_n = 1'b0; cpu_rst_n = 1'b1;
    end
    always #6.734 vclk = ~vclk;     // 74.25 MHz
    always #3     sclk = ~sclk;     // 166.7 MHz
    always #5     pclk = ~pclk;     // 100 MHz (APB)
    initial #100 rst_n = 1'b1;
    wire vrst_n, srst_n, presetn;
    ae350_reset_sync u_vrst (.clk (vclk), .rst_n_in (rst_n), .rst_n_out (vrst_n));
    ae350_reset_sync u_srst (.clk (sclk), .rst_n_in (rst_n), .rst_n_out (srst_n));
    ae350_reset_sync u_prst (.clk (pclk), .rst_n_in (rst_n & cpu_rst_n), .rst_n_out (presetn));

    // ---------------------------------------------------------
    // HDMI (座標を作る。音声は無音)
    // ---------------------------------------------------------
    wire               clk_audio;
    wire signed [15:0] sample;
    hdmi_audio_tone #(.CLK_HZ(74250000), .RATE(48000), .TONE_HZ(1000), .AMPLITUDE(0)) u_tone (
        .clk (vclk), .reset (!vrst_n), .clk_audio (clk_audio), .sample (sample)
    );
    logic [15:0] audio_word [1:0];
    assign audio_word[0] = sample;
    assign audio_word[1] = sample;

    wire [10:0] cx;
    wire [9:0]  cy;
    wire [23:0] rgb;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0]  tmds;
    wire        tmds_clock;
    wire [10:0] frame_width, screen_width;
    wire [9:0]  frame_height, screen_height;
    /* verilator lint_on UNUSEDSIGNAL */
    hdmi #(.VIDEO_ID_CODE (4), .VIDEO_REFRESH_RATE (60.0), .AUDIO_RATE (48000), .AUDIO_BIT_WIDTH (16)) u_hdmi (
        .clk_pixel_x5 (1'b0), .clk_pixel (vclk), .clk_audio (clk_audio), .reset (!vrst_n), .serializer_reset (!vrst_n),
        .rgb (rgb), .audio_sample_word (audio_word), .tmds (tmds), .tmds_clock (tmds_clock), .cx (cx), .cy (cy),
        .frame_width (frame_width), .frame_height (frame_height), .screen_width (screen_width), .screen_height (screen_height)
    );

    // ---------------------------------------------------------
    // 表示の回路、読み出しの回路、SDRAM
    // ---------------------------------------------------------
    logic        psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    logic [31:0] paddr = 32'd0, pwdata = 32'd0;
    logic [3:0]  pstrb = 4'hF;
    wire  [31:0] prdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire         pready, pslverr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire         mreq, lb_we, mdone;
    wire  [24:0] mreq_addr;
    wire  [10:0] lb_waddr;
    wire  [15:0] lb_wdata;
    wire         mrst_n_fb;   // 表示の回路が出す、メモリのクロック側のリセット

    fb_display u_fb (
        .pclk (pclk), .presetn (presetn), .psel (psel), .penable (penable), .pwrite (pwrite), .paddr (paddr),
        .pwdata (pwdata), .pstrb (pstrb), .prdata (prdata), .pready (pready), .pslverr (pslverr),
        .vclk (vclk), .vrst_n (vrst_n), .cx (cx), .cy (cy), .rgb (rgb),
        .mclk (sclk), .mrst_n (srst_n), .mreq (mreq), .mreq_addr (mreq_addr), .lb_we (lb_we), .lb_waddr (lb_waddr),
        .lb_wdata (lb_wdata), .mdone (mdone), .mrst_n_out (mrst_n_fb)
    );

    // 要求を 1 回だけ遅らせる (delay_addr の要求を、DELAY_CLK クロック後に渡す)
    localparam int DELAY_CLK = 3000;    // 18 µs (1 ラインは 22.2 µs。読み出しに約 8 µs かかるので、間に合わなくなる)
    logic        delay_armed = 1'b0;
    logic [24:0] delay_addr  = 25'd0;
    logic        delay_used, delay_hold, mreq_d;
    logic [24:0] mreq_addr_d, hold_addr;
    int          delay_cnt;
    int          n_mreq;
    initial begin
        delay_used = 1'b0; delay_hold = 1'b0; mreq_d = 1'b0; mreq_addr_d = 25'd0; hold_addr = 25'd0; delay_cnt = 0; n_mreq = 0;
    end
    always @(posedge sclk) begin
        mreq_d <= 1'b0;
        if (mreq) begin
            n_mreq <= n_mreq + 1;
            if (delay_armed && !delay_used && mreq_addr == delay_addr) begin
                delay_used <= 1'b1;
                delay_hold <= 1'b1;
                hold_addr  <= mreq_addr;
                delay_cnt  <= DELAY_CLK;
            end else begin
                mreq_d      <= 1'b1;
                mreq_addr_d <= mreq_addr;
            end
        end
        if (delay_hold) begin
            if (delay_cnt == 0) begin
                delay_hold  <= 1'b0;
                mreq_d      <= 1'b1;
                mreq_addr_d <= hold_addr;
            end else begin
                delay_cnt <= delay_cnt - 1;
            end
        end
    end

    wire        dr_start, dr_busy, dr_wvalid, dr_done;
    wire [20:0] dr_addr, dr_bursts;
    wire [15:0] dr_wdata;
    fb_sdram_reader u_reader (
        .clk (sclk), .rst_n (mrst_n_fb), .mreq (mreq_d), .mreq_addr (mreq_addr_d), .lb_we (lb_we), .lb_waddr (lb_waddr),
        .lb_wdata (lb_wdata), .mdone (mdone), .dr_start (dr_start), .dr_addr (dr_addr), .dr_bursts (dr_bursts),
        .dr_busy (dr_busy), .dr_wvalid (dr_wvalid), .dr_wdata (dr_wdata), .dr_done (dr_done)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire         fill_ready, wready, init_done;
    wire [127:0] fill_data;
    /* verilator lint_on UNUSEDSIGNAL */
    sdram_hs_path #(.ADDR_WIDTH (25), .RD_FIRST (11), .IN_DLY (160), .CAP_EDGE (0)) u_path (
        .s_clk (sclk), .rst_n (srst_n), .fill_valid (1'b0), .fill_line (21'd0), .fill_ready (fill_ready), .fill_data (fill_data),
        .we (1'b0), .waddr (25'd0), .wdata (64'd0), .wmask (8'd0), .wready (wready), .init_done (init_done),
        .dr_start (dr_start), .dr_addr (dr_addr), .dr_bursts (dr_bursts), .dr_busy (dr_busy), .dr_wvalid (dr_wvalid),
        .dr_wdata (dr_wdata), .dr_done (dr_done)
    );

    // ---------------------------------------------------------
    // 模様と期待値
    // ---------------------------------------------------------
    // バイトアドレスを、SDRAM のモデルの内容のアドレス ({バンク, 行, 列}) に変換する (sdram_ctrl_hs は {行, バンク, 列})
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int mi(input logic [24:0] a);    // ビット 0 は使わない (16 ビットワードのアドレス)
        logic [23:0] w;
        w = a[24:1];
        return {8'd0, w[10:9], w[23:11], w[8:0]};
    endfunction
    function automatic logic [15:0] pat(input logic [24:0] a);
        return a[16:1] ^ {a[24:17], 8'h5A};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function automatic logic [23:0] expand(input logic [15:0] p);
        return {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction

    wire [23:0] bar_rgb;
    hdmi_test_pattern u_ref (.clk (vclk), .cx (cx), .rgb (bar_rgb));

    // 期待: 今のフレームの表示 (cur_*) と、次のフレームから使う表示 (nxt_*。テストの手順が決める)
    logic        nxt_fb = 1'b0, cur_fb;
    logic [24:0] nxt_base = FB_A, cur_base;
    int          nxt_bar_line = -1, cur_bar_line;    // このラインだけカラーバー
    int          frame_no;                           // テストベンチが数えるフレーム (ライン 0 の始まりで 1 増える)
    int          n_fb, n_bar;
    int          skip_frame = -1, skip_line = 0;      // このフレームのこのライン (cy) からは比べない
    logic [10:0] cx_q;
    logic [9:0]  cy_q;
    logic        started;                            // リセットの後、最初のフレームが始まった
    initial begin
        cur_fb = 1'b0; cur_base = FB_A; cur_bar_line = -1; frame_no = 0; n_fb = 0; n_bar = 0; cx_q = 11'd0; cy_q = 10'd0;
        started = 1'b0;
    end
    // フレームの始まり: リセットの後に初めて (0, 0) になったときと、cy が最後のラインから 0 に戻ったとき
    // (リセットの間も hdmi.sv の座標は (0, 0) にとどまるので、(0, 0) だけでは数えない)
    wire frame_start = vrst_n && cx == 11'd0 && cy == 10'd0 && (!started || cy_q != 10'd0);
    always @(posedge vclk) begin
        cx_q <= cx;
        cy_q <= cy;
        if (frame_start) begin
            started      <= 1'b1;
            cur_fb       <= nxt_fb;
            cur_base     <= nxt_base;
            cur_bar_line <= nxt_bar_line;
            frame_no     <= frame_no + 1;
        end
        // 1 つ前の座標の画素 (hdmi.sv がこのエッジで受け取る色)
        if (vrst_n && frame_no >= 1 && int'(cx_q) < H_ACTIVE && int'(cy_q) < V_ACTIVE &&
            !(frame_no == skip_frame && int'(cy_q) >= skip_line)) begin
            if (cur_fb && int'(cy_q) != cur_bar_line) begin
                logic [24:0] a;
                a = cur_base + 25'(cy_q) * 25'(STRIDE) + 25'(cx_q) * 25'd2;
                if (rgb !== expand(pat(a)))
                    $fatal(1, "frame %0d (%0d, %0d): rgb %06x, expected %06x (frame buffer 0x%07x)", frame_no, cx_q, cy_q, rgb,
                           expand(pat(a)), cur_base);
                n_fb <= n_fb + 1;
            end else begin
                if (rgb !== bar_rgb)
                    $fatal(1, "frame %0d (%0d, %0d): rgb %06x, expected color bar %06x", frame_no, cx_q, cy_q, rgb, bar_rgb);
                n_bar <= n_bar + 1;
            end
        end
    end

    // ---------------------------------------------------------
    // APB
    // ---------------------------------------------------------
    task automatic apb_write(input logic [31:0] a, input logic [31:0] d);
        @(posedge pclk);
        psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b1; paddr <= a; pwdata <= d; pstrb <= 4'hF;
        @(posedge pclk);
        penable <= 1'b1;
        @(posedge pclk);
        psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
    endtask
    task automatic apb_read(input logic [31:0] a, output logic [31:0] d);
        @(posedge pclk);
        psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b0; paddr <= a;
        @(posedge pclk);
        penable <= 1'b1;
        @(posedge pclk);
        d = prdata;
        psel <= 1'b0; penable <= 1'b0;
    endtask
    task automatic expect_reg(input logic [31:0] a, input logic [31:0] v, input string what);
        logic [31:0] d;
        apb_read(a, d);
        if (d !== v) $fatal(1, "%s: register +0x%02x is %08x, expected %08x", what, a, d, v);
    endtask

    // テストベンチのフレーム f の、ライン y の始まりまで待つ (フレームの番号は (0, 0) のエッジで増えるので、cx は見ない)
    task automatic wait_line(input int f, input int y);
        while (!(frame_no == f && int'(cy) == y)) @(posedge vclk);
    endtask

    // ---------------------------------------------------------
    // 手順
    // ---------------------------------------------------------
    logic [31:0] d0, d1;
    int          nb, nf, nm;
    initial begin
        // 模様を置く (A と B の 720 ライン)
        for (int y = 0; y < V_ACTIVE; y++) begin
            for (int x = 0; x < H_ACTIVE; x++) begin
                u_path.u_model.mem[mi(FB_A + 25'(y * STRIDE + x * 2))] = pat(FB_A + 25'(y * STRIDE + x * 2));
                u_path.u_model.mem[mi(FB_B + 25'(y * STRIDE + x * 2))] = pat(FB_B + 25'(y * STRIDE + x * 2));
            end
        end

        // フレーム 1: ENABLE 0。レジスタのリセット後の値
        wait_line(1, 10);
        expect_reg(32'h0, 32'd0, "CTRL after reset");
        expect_reg(32'h4, {7'd0, FB_A}, "FB_BASE after reset");
        expect_reg(32'hC, 32'd0, "STATUS after reset");
        apb_write(32'h4, 32'h0100_000F);
        expect_reg(32'h4, 32'h0100_0000, "FB_BASE low 4 bits");
        apb_write(32'h4, {7'd0, FB_A});
        // フレーム 2 から A を表示する
        wait_line(1, 400);
        if (!init_done) $fatal(1, "SDRAM is not initialized at line 400 of frame 1");
        apb_write(32'h0, 32'd1);
        expect_reg(32'h0, 32'd1, "CTRL");
        nxt_fb = 1'b1; nxt_base = FB_A;
        wait_line(2, 0);
        if (n_bar != H_ACTIVE * V_ACTIVE || n_fb != 0) $fatal(1, "frame 1: %0d color bar pixels, %0d frame buffer pixels", n_bar, n_fb);
        $display("frame 1 (ENABLE 0, color bar, registers after reset): PASS");

        // フレーム 3 のライン 360 で FB_BASE = B
        nb = n_bar; nf = n_fb;
        wait_line(3, 0);
        if (n_fb - nf != H_ACTIVE * V_ACTIVE || n_bar != nb) $fatal(1, "frame 2: %0d frame buffer pixels, %0d color bar pixels", n_fb - nf, n_bar - nb);
        $display("frame 2 (ENABLE 1, frame buffer A, all 720 lines): PASS");
        nf = n_fb;
        apb_read(32'h8, d0);
        wait_line(3, 360);
        apb_write(32'h4, {7'd0, FB_B});
        nxt_base = FB_B;
        wait_line(4, 0);
        if (n_fb - nf != H_ACTIVE * V_ACTIVE) $fatal(1, "frame 3: %0d frame buffer pixels", n_fb - nf);
        $display("frame 3 (FB_BASE written at line 360, still A until the end): PASS");

        // フレーム 4: B。FRAME がフレームごとに 1 増える。UNDERRUN は 0
        nf = n_fb;
        apb_read(32'h8, d1);
        if (d1 - d0 != 1) $fatal(1, "FRAME went from %0d to %0d in one frame", d0, d1);
        wait_line(4, 700);
        expect_reg(32'hC, 32'd0, "STATUS before the delayed request");
        // フレーム 5 のライン 100 の要求を遅らせる (ライン 100 の要求は、ライン 99 の始まりで出る)
        delay_addr   = FB_B + 25'(100 * STRIDE);
        delay_armed  = 1'b1;
        nxt_bar_line = 100;
        wait_line(5, 0);
        if (n_fb - nf != H_ACTIVE * V_ACTIVE) $fatal(1, "frame 4: %0d frame buffer pixels", n_fb - nf);
        $display("frame 4 (frame buffer B, FRAME counts each frame, no underrun): PASS");

        // フレーム 5: ライン 100 だけカラーバー。UNDERRUN
        nb = n_bar; nf = n_fb;
        wait_line(5, 400);
        if (!delay_used) $fatal(1, "the request for line 100 was not delayed");
        expect_reg(32'hC, 32'd1, "STATUS after the delayed request");
        apb_write(32'hC, 32'd1);
        expect_reg(32'hC, 32'd0, "STATUS after writing 1");
        // フレーム 6 は ENABLE 0
        apb_write(32'h0, 32'd0);
        nxt_fb = 1'b0; nxt_bar_line = -1;
        wait_line(6, 0);
        if (n_bar - nb != H_ACTIVE || n_fb - nf != H_ACTIVE * (V_ACTIVE - 1))
            $fatal(1, "frame 5: %0d color bar pixels, %0d frame buffer pixels", n_bar - nb, n_fb - nf);
        $display("frame 5 (request for line 100 delayed: only line 100 is a color bar, UNDERRUN set and cleared): PASS");

        // フレーム 6: カラーバーで、要求が出ない
        nb = n_bar; nf = n_fb; nm = n_mreq;
        wait_line(7, 0);
        if (n_bar - nb != H_ACTIVE * V_ACTIVE || n_fb != nf) $fatal(1, "frame 6: %0d color bar pixels, %0d frame buffer pixels", n_bar - nb, n_fb - nf);
        if (n_mreq != nm) $fatal(1, "frame 6: %0d read requests with ENABLE 0", n_mreq - nm);
        $display("frame 6 (ENABLE 0 again, color bar, no read requests): PASS");

        // フレーム 7: CTRL に 1 を書く (次のフレームから B)
        nb = n_bar;
        wait_line(7, 10);
        apb_write(32'h0, 32'd1);
        nxt_fb = 1'b1;
        wait_line(8, 0);
        if (n_bar - nb != H_ACTIVE * V_ACTIVE) $fatal(1, "frame 7: %0d color bar pixels", n_bar - nb);
        // リセットの前のトグルが 0 であること (CPU のリセットで APB 側のトグルが変わらず、表示の回路が設定の変化を受け取らない場合)
        if (u_fb.cfg_tgl !== 1'b0) $fatal(1, "the configuration toggle is not 0 before the CPU reset");
        $display("frame 7 (ENABLE written, color bar): PASS");

        // フレーム 8: ライン 300 で、表示用の読み出しの最中に CPU のリセットをかける
        nf = n_fb;
        wait_line(8, 300);
        @(posedge sclk);
        while (!dr_busy) @(posedge sclk);
        repeat (50) @(posedge sclk);
        if (!dr_busy) $fatal(1, "no display read in progress at the CPU reset");
        skip_frame = 8; skip_line = int'(cy);
        cpu_rst_n = 1'b0;
        nxt_fb = 1'b0; nxt_base = FB_A;
        repeat (20) @(posedge pclk);
        cpu_rst_n = 1'b1;
        if (n_fb - nf < H_ACTIVE * 300) $fatal(1, "frame 8: %0d frame buffer pixels before the CPU reset", n_fb - nf);
        $display("frame 8 (frame buffer B, CPU reset during a display read at line %0d): PASS", skip_line);

        // フレーム 9: カラーバー。レジスタはリセットの後の値。読み出しの要求が出ない
        nb = n_bar; nf = n_fb;
        wait_line(9, 0);
        nm = n_mreq;
        wait_line(9, 10);
        expect_reg(32'h0, 32'd0, "CTRL after the CPU reset");
        expect_reg(32'h4, {7'd0, FB_A}, "FB_BASE after the CPU reset");
        // FRAME は、リセットの後にフレーム 8 のライン 720 で 1 回だけ増える (リセットの直後に増えることはない)
        expect_reg(32'h8, 32'd1, "FRAME after the CPU reset");
        expect_reg(32'hC, 32'd0, "STATUS after the CPU reset");
        wait_line(9, 400);
        if (n_mreq != nm) $fatal(1, "frame 9: %0d read requests after the CPU reset", n_mreq - nm);
        apb_write(32'h0, 32'd1);
        nxt_fb = 1'b1;
        wait_line(10, 0);
        if (n_bar - nb != H_ACTIVE * V_ACTIVE || n_fb != nf) $fatal(1, "frame 9: %0d color bar pixels, %0d frame buffer pixels", n_bar - nb, n_fb - nf);
        $display("frame 9 (after the CPU reset: color bar, registers reset, no read requests): PASS");

        // フレーム 10: A。UNDERRUN が 0
        nf = n_fb;
        wait_line(11, 0);
        if (n_fb - nf != H_ACTIVE * V_ACTIVE) $fatal(1, "frame 10: %0d frame buffer pixels", n_fb - nf);
        expect_reg(32'hC, 32'd0, "STATUS in frame 11");
        $display("frame 10 (frame buffer A after the CPU reset, no underrun): PASS");
        $display("fb_display_tb: PASS (%0d frame buffer pixels, %0d color bar pixels)", n_fb, n_bar);
        $finish;
    end
endmodule

`default_nettype wire
