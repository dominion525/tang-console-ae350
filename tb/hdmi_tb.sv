// =============================================================
// File:        tb/hdmi_tb.sv
// Module:      hdmi_tb
// Role:        HDMI の出力回路 (rtl/vendor/hdmi/hdmi.sv) のテストベンチ。1280×720 / 60 Hz (VIC 4)、音声 48 kHz の構成で、
//              テストパターン (rtl/hdmi_test_pattern.v) と試験音 (rtl/hdmi_audio_tone.v) をつなぎ、hdmi.sv の内部の
//              10 ビットの TMDS の値 (tmds_internal。シリアライザは Verilator では空になるため) を、このテストベンチの中で
//              復号して確かめる。hdmi.sv の座標の出力 (cx、cy) は判定に使わない。期待と違えば $fatal で止まる。
//
//   基準の位置: 1 行目の映像の直前のビデオガードバンド。ガードバンドの前に 2 ライン以上ガードバンドがなければ、
//               次のクロックを (x, y) = (0, 0) とし、そこから 1 クロックごとに位置を進めて、位置ごとに期待する符号と比べる
//   確かめること (2 フレーム目と 3 フレーム目。1 フレーム目はリセット直後を含むので、基準の位置を探すだけ)
//     - 位置ごとの符号の種類 (映像、制御、ガードバンド、データアイランド) と、プリアンブルの CTL の値
//     - 同期信号の位置と極性 (水平は x = 1390〜1429、垂直は 724 ライン目の x = 1390 から 729 ライン目の x = 1389 まで、正極性)
//     - 映像の値がカラーバーの色と合う
//     - 映像期間の中の直流の偏り (1 と 0 の数の差の累計) が ±10 に収まる
//     - パケットのヘッダとサブパケットの ECC (BCH)
//     - 音声サンプルのパケット (種類 0x02) が 1 フレームで運ぶサンプル数が 800 前後で、値が試験音の ±振幅
//     - 音声クロック再生のパケット (種類 0x01) の N が 6144、CTS が 74250 (±1)
//
// 実行: make test-hdmi
// =============================================================

`timescale 1ns/1ps
`default_nettype none

module hdmi_tb;

    // VIC 4 (CEA-861)。x は映像の 1 画素目からのクロック数、y は映像の 1 行目からのライン数
    localparam int H_TOTAL      = 1650;
    localparam int V_TOTAL      = 750;
    localparam int H_ACTIVE     = 1280;
    localparam int V_ACTIVE     = 720;
    localparam int H_SYNC_START = 1390;
    localparam int H_SYNC_END   = 1430;
    localparam int V_SYNC_START = 724;    // このラインの H_SYNC_START から垂直同期
    localparam int V_SYNC_END   = 729;    // このラインの H_SYNC_START で垂直同期が終わる
    // hdmi.sv の帰線期間の並び (1 ラインに 10 個のパケット)
    localparam int DI_PRE       = H_ACTIVE + 4;      // データアイランドのプリアンブル (8 クロック)
    localparam int DI_LEAD      = H_ACTIVE + 12;     // 前のガードバンド (2 クロック)
    localparam int DI_PKT       = H_ACTIVE + 14;     // パケット (32 クロックずつ)
    localparam int DI_NPKT      = 10;
    localparam int DI_TRAIL     = DI_PKT + DI_NPKT * 32;   // 後ろのガードバンド (2 クロック)
    localparam int V_PRE        = H_TOTAL - 10;      // ビデオのプリアンブル (8 クロック)
    localparam int V_GUARD      = H_TOTAL - 2;       // ビデオのガードバンド (2 クロック)

    localparam int AMPLITUDE    = 2048;
    localparam int CHECK_FRAMES = 2;

    // ---------------------------------------------------------
    // 回路
    // ---------------------------------------------------------
    logic clk;
    logic reset;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire               clk_audio;
    wire signed [15:0] sample;
    hdmi_audio_tone #(.CLK_HZ(74250000), .RATE(48000), .TONE_HZ(1000), .AMPLITUDE(AMPLITUDE)) u_tone (
        .clk (clk), .reset (reset), .clk_audio (clk_audio), .sample (sample)
    );

    logic [15:0] audio_word [1:0];
    assign audio_word[0] = sample;
    assign audio_word[1] = sample;

    wire [10:0] cx;
    wire [23:0] rgb;
    hdmi_test_pattern u_pattern (.clk (clk), .cx (cx), .rgb (rgb));

    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0]  tmds;          // シリアライザの出力 (Verilator では駆動されない)
    wire        tmds_clock;
    wire [9:0]  cy;
    wire [10:0] frame_width;
    wire [9:0]  frame_height;
    wire [10:0] screen_width;
    wire [9:0]  screen_height;
    /* verilator lint_on UNUSEDSIGNAL */

    hdmi #(
        .VIDEO_ID_CODE      (4),
        .VIDEO_REFRESH_RATE (60.0),
        .AUDIO_RATE         (48000),
        .AUDIO_BIT_WIDTH    (16)
    ) dut (
        .clk_pixel_x5      (1'b0),
        .clk_pixel         (clk),
        .clk_audio         (clk_audio),
        .reset             (reset),
        .rgb               (rgb),
        .audio_sample_word (audio_word),
        .tmds              (tmds),
        .tmds_clock        (tmds_clock),
        .cx                (cx),
        .cy                (cy),
        .frame_width       (frame_width),
        .frame_height      (frame_height),
        .screen_width      (screen_width),
        .screen_height     (screen_height)
    );

    // ---------------------------------------------------------
    // 符号の復号 (HDMI 1.4b 5.4)
    // ---------------------------------------------------------
    // 制御の符号 (5.4.2)。{C1, C0} を返し、制御の符号でなければ -1
    function automatic int ctrl_decode(input logic [9:0] s);
        case (s)
            10'b1101010100: return 0;
            10'b0010101011: return 1;
            10'b0101010100: return 2;
            10'b1010101011: return 3;
            default:        return -1;
        endcase
    endfunction

    // TERC4 (5.4.3)。4 ビットの値を返し、TERC4 の符号でなければ -1
    function automatic int terc4_decode(input logic [9:0] s);
        case (s)
            10'b1010011100: return 0;
            10'b1001100011: return 1;
            10'b1011100100: return 2;
            10'b1011100010: return 3;
            10'b0101110001: return 4;
            10'b0100011110: return 5;
            10'b0110001110: return 6;
            10'b0100111100: return 7;
            10'b1011001100: return 8;
            10'b0100111001: return 9;
            10'b0110011100: return 10;
            10'b1011000110: return 11;
            10'b1010001110: return 12;
            10'b1001110001: return 13;
            10'b0101100011: return 14;
            10'b1011000011: return 15;
            default:        return -1;
        endcase
    endfunction

    // 映像の符号 (5.4.4) を 8 ビットに戻す
    function automatic logic [7:0] video_decode(input logic [9:0] s);
        logic [7:0] q;
        logic [7:0] d;
        q = s[9] ? ~s[7:0] : s[7:0];
        d[0] = q[0];
        for (int i = 1; i < 8; i++)
            d[i] = s[8] ? (q[i] ^ q[i-1]) : ~(q[i] ^ q[i-1]);
        return d;
    endfunction

    // カラーバーの色 ({赤, 緑, 青})
    function automatic logic [23:0] bar_color(input int x);
        case (x / 160)
            0:       return 24'hFFFFFF;
            1:       return 24'hFFFF00;
            2:       return 24'h00FFFF;
            3:       return 24'h00FF00;
            4:       return 24'hFF00FF;
            5:       return 24'hFF0000;
            6:       return 24'h0000FF;
            default: return 24'h000000;
        endcase
    endfunction

    // 期待する同期信号
    function automatic bit hsync_at(input int x);
        return x >= H_SYNC_START && x < H_SYNC_END;
    endfunction
    function automatic bit vsync_at(input int x, input int y);
        if (y == V_SYNC_START) return x >= H_SYNC_START;
        if (y == V_SYNC_END)   return x < H_SYNC_START;
        return y > V_SYNC_START && y < V_SYNC_END;
    endfunction

    // BCH の ECC (5.2.3.4、生成多項式 1 + x^6 + x^7 + x^8)。bits の下位 n ビットを、ビット 0 から順に送る
    function automatic logic [7:0] bch_ecc(input logic [55:0] bits, input int n);
        logic [7:0] e;
        e = 8'd0;
        for (int i = 0; i < n; i++)
            e = (e >> 1) ^ ((e[0] ^ bits[i]) ? 8'b10000011 : 8'd0);
        return e;
    endfunction

    // ---------------------------------------------------------
    // 判定
    // ---------------------------------------------------------
    // 判定の状態 (下の initial で初期化する)
    int  frame;                // 判定したフレームの数
    int  x, y;                 // 判定している符号の位置
    int  disparity, max_disparity;
    int  samples_in_frame, packets_in_frame;
    int  acr_seen;

    logic [31:0] hdr;
    logic [63:0] bch [4];

    task automatic fail(input string msg);
        $fatal(1, "FAIL frame %0d (x, y) = (%0d, %0d): %s", frame, x, y, msg);
    endtask

    // 1 クロック分の符号を、位置 (x, y) で期待するものと比べる
    task automatic check_symbol(input logic [9:0] s0, input logic [9:0] s1, input logic [9:0] s2);
        int c0, c1, c2, d0, d1, d2;
        bit in_line_video = y < V_ACTIVE && x < H_ACTIVE;
        bit before_video  = (y == V_TOTAL - 1) || (y < V_ACTIVE - 1);   // 次のラインが映像のライン
        logic [23:0] got;
        int j;

        if (in_line_video) begin
            got = {video_decode(s2), video_decode(s1), video_decode(s0)};
            if (got !== bar_color(x))
                fail($sformatf("video %06h, expected %06h", got, bar_color(x)));
            // 3 チャンネルとも同じ規則なので、チャンネル 0 の累計を見る
            disparity += $countones(s0) * 2 - 10;
            if (disparity > max_disparity)  max_disparity = disparity;
            if (-disparity > max_disparity) max_disparity = -disparity;
            if (disparity > 10 || disparity < -10)
                fail($sformatf("running disparity %0d", disparity));
            return;
        end
        disparity = 0;

        if (before_video && x >= V_GUARD) begin
            if (s0 !== 10'b1011001100 || s1 !== 10'b0100110011 || s2 !== 10'b1011001100)
                fail($sformatf("video guard band %b %b %b", s0, s1, s2));
            return;
        end

        if (x >= DI_LEAD && x < DI_PKT || x >= DI_TRAIL && x < DI_TRAIL + 2) begin
            d0 = terc4_decode(s0);
            if (s1 !== 10'b0100110011 || s2 !== 10'b0100110011 || d0 < 0 || d0[3:2] !== 2'b11)
                fail($sformatf("data island guard band %b %b %b", s0, s1, s2));
            if (d0[0] !== hsync_at(x) || d0[1] !== vsync_at(x, y))
                fail($sformatf("sync in data island guard band: h %0d v %0d", d0[0], d0[1]));
            return;
        end

        if (x >= DI_PKT && x < DI_TRAIL) begin
            d0 = terc4_decode(s0);
            d1 = terc4_decode(s1);
            d2 = terc4_decode(s2);
            if (d0 < 0 || d1 < 0 || d2 < 0)
                fail($sformatf("data island symbol is not TERC4: %b %b %b", s0, s1, s2));
            if (d0[0] !== hsync_at(x) || d0[1] !== vsync_at(x, y))
                fail($sformatf("sync in data island: h %0d v %0d", d0[0], d0[1]));
            j = (x - DI_PKT) % 32;
            hdr[j] = d0[2];
            for (int k = 0; k < 4; k++) begin
                bch[k][2*j]   = d1[k];
                bch[k][2*j+1] = d2[k];
            end
            if (j == 31) check_packet();
            return;
        end

        // それ以外は制御期間
        c0 = ctrl_decode(s0);
        c1 = ctrl_decode(s1);
        c2 = ctrl_decode(s2);
        if (c0 < 0 || c1 < 0 || c2 < 0)
            fail($sformatf("control symbol expected: %b %b %b", s0, s1, s2));
        if (c0[0] !== hsync_at(x) || c0[1] !== vsync_at(x, y))
            fail($sformatf("sync: h %0d (expected %0d) v %0d (expected %0d)", c0[0], hsync_at(x), c0[1], vsync_at(x, y)));
        // CTL0〜CTL3 (チャンネル 1 の {C1, C0} = {CTL1, CTL0}、チャンネル 2 = {CTL3, CTL2})
        if (x >= DI_PRE && x < DI_LEAD) begin
            if (c1 != 1 || c2 != 1) fail($sformatf("data island preamble CTL %0d %0d", c1, c2));
        end else if (before_video && x >= V_PRE) begin
            if (c1 != 1 || c2 != 0) fail($sformatf("video preamble CTL %0d %0d", c1, c2));
        end else begin
            if (c1 != 0 || c2 != 0) fail($sformatf("CTL %0d %0d outside preambles", c1, c2));
        end
    endtask

    // 32 クロック分のパケットを受け取った後の判定
    task automatic check_packet();
        logic [7:0] sb [7];
        int n, cts;
        if (bch_ecc({32'd0, hdr[23:0]}, 24) !== hdr[31:24])
            fail($sformatf("header ECC %02h, expected %02h (header %06h)", hdr[31:24], bch_ecc({32'd0, hdr[23:0]}, 24), hdr[23:0]));
        for (int k = 0; k < 4; k++)
            if (bch_ecc(bch[k][55:0], 56) !== bch[k][63:56])
                fail($sformatf("subpacket %0d ECC %02h, expected %02h (type %02h)", k, bch[k][63:56], bch_ecc(bch[k][55:0], 56), hdr[7:0]));

        case (hdr[7:0])
            8'h01: begin   // 音声クロック再生 (5.3.3)。4 つのサブパケットは同じ内容
                for (int b = 0; b < 7; b++) sb[b] = bch[0][8*b +: 8];
                cts = 32'({sb[1][3:0], sb[2], sb[3]});
                n   = 32'({sb[4][3:0], sb[5], sb[6]});
                if (n != 6144)
                    fail($sformatf("ACR N = %0d, expected 6144", n));
                if (cts < 74249 || cts > 74251)
                    fail($sformatf("ACR CTS = %0d, expected 74250 +/- 1", cts));
                acr_seen++;
            end
            8'h02: begin   // 音声サンプル (5.3.4)。ヘッダのビット 8〜11 が、サブパケットごとのサンプルの有無
                packets_in_frame++;
                for (int k = 0; k < 4; k++) begin
                    if (hdr[8 + k]) begin
                        samples_in_frame++;
                        // 左右とも 24 ビットに左詰め (16 ビットのサンプルは上位 16 ビット)
                        if (!(bch[k][23:8] == 16'(AMPLITUDE) || bch[k][23:8] == 16'(-AMPLITUDE)) ||
                            bch[k][47:32] != bch[k][23:8])
                            fail($sformatf("audio sample L %04h R %04h, expected +/- %0d on both", bch[k][23:8], bch[k][47:32], AMPLITUDE));
                    end
                end
            end
            default: ;
        endcase
    endtask

    initial begin
        int  t;                // リセットを解除してからのクロック数
        int  last_guard;       // 最後にビデオガードバンドの 2 クロック目を見たクロック
        int  guard_run;        // 続けて見たビデオガードバンドの数
        logic [9:0] s0, s1, s2;

        frame = 0; x = 0; y = 0;
        disparity = 0; max_disparity = 0;
        samples_in_frame = 0; packets_in_frame = 0; acr_seen = 0;
        t = 0; last_guard = -1; guard_run = 0;
        reset = 1'b1;

        repeat (4) @(posedge clk);
        reset = 1'b0;

        // 基準の位置を探す: ビデオガードバンドの 2 クロック目で、その前の 2 ライン以上ガードバンドがない
        forever begin
            @(posedge clk);
            s0 = dut.tmds_internal[0];
            s1 = dut.tmds_internal[1];
            s2 = dut.tmds_internal[2];
            t++;
            if (t > 3 * H_TOTAL * V_TOTAL)
                $fatal(1, "FAIL: no frame start found");
            if (s0 === 10'b1011001100 && s1 === 10'b0100110011 && s2 === 10'b1011001100) begin
                guard_run++;
                if (guard_run == 2) begin
                    if (last_guard >= 0 && t - last_guard > 2 * H_TOTAL) break;
                    last_guard = t;
                end
            end else begin
                guard_run = 0;
            end
        end
        $display("hdmi_tb: locked at clock %0d", t);

        // 次のクロックの符号が (0, 0)。1 クロックごとに位置を進めて判定する
        forever begin
            @(posedge clk);
            check_symbol(dut.tmds_internal[0], dut.tmds_internal[1], dut.tmds_internal[2]);
            x++;
            if (x == H_TOTAL) begin
                x = 0;
                y++;
                if (y == V_TOTAL) begin
                    y = 0;
                    $display("hdmi_tb: frame %0d: %0d audio sample packets, %0d samples, %0d ACR packets so far, max running disparity %0d",
                             frame, packets_in_frame, samples_in_frame, acr_seen, max_disparity);
                    if (samples_in_frame < 796 || samples_in_frame > 804)
                        fail($sformatf("%0d audio samples in a frame, expected 800 +/- 4", samples_in_frame));
                    samples_in_frame = 0;
                    packets_in_frame = 0;
                    frame++;
                    if (frame == CHECK_FRAMES) begin
                        if (acr_seen == 0) fail("no ACR packet");
                        $display("PASS hdmi_tb: %0d frames", frame);
                        $finish;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
