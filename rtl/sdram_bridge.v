// =============================================================
// File:        rtl/sdram_bridge.v
// Module:      sdram_bridge
// Role:        上位の回路 (rtl/ahb_sdram.v) からのライン読み出しポートと書き込みポートを、SDR SDRAM
//              (W9825G6KH-6) のコマンドに変換する。ライン読み出しは 8 ワードのバースト、書き込みは 1 ワード。どちらも
//              オートプリチャージ付き。SDRAM の初期化とリフレッシュもここで行う。クロックは clk 1 本。
//
//              SDRAM のクロックは clk の逆相 (上位のトップが ~clk を出力する)。コマンドは clk の立ち上がりで変わり、SDRAM は
//              半サイクル後の立ち上がりで取り込む。CL = 2 なので、読み出しの最初のワードは、取り込んだ 1 サイクル後の SDRAM
//              の立ち上がりから tAC (6 ns) で出力され、次の立ち上がりの tOH (3 ns) まで保持される。READ を出した clk の
//              エッジから 2 つ後のエッジで取り込む。20 MHz なら、ピンまでのクロックの遅延が 19 ns 程度まで許容できる。
//
// Parameters:
//   ADDR_WIDTH     = 25                   バイトアドレスの幅 (32 MB。W9825G6KH の容量)
//   INIT_CYCLES    = 4000                 電源投入後の待ち時間 (200 us、20 MHz)
//   REFRESH_CYCLES = 152                  リフレッシュの間隔 (7.6 us、20 MHz)
//
// Ports:
//   (上位の回路側)
//   input  wire clk, rst_n
//   input  wire                   fill_valid    ラインを読み出してほしい間 1
//   input  wire [ADDR_WIDTH-5:0]  fill_line     ラインのアドレス (バイトアドレスの上位。16 バイト境界)
//   output reg                    fill_ready    ラインを出力したサイクルに 1
//   output reg  [127:0]           fill_data     ラインの 16 バイト。アドレスの小さいバイトが下位
//   input  wire                   we            書き込んでほしい間 1
//   input  wire [ADDR_WIDTH-1:0]  waddr         8 バイト境界 (下位 3 ビットは見ない)
//   input  wire [63:0]            wdata         8 バイト。アドレスの小さいバイトが下位
//   input  wire [7:0]             wmask         書き込むバイト (1 のバイトだけ書き込む)
//   output reg                    wready        全バイトを受け付けた次のサイクルに 1 (sdram_ctrl_hs と同じポート。この 20 MHz 版は、
//                                               中で 1 バイトずつ書き込む)
//   output reg                    init_done     SDRAM の初期化が終わった。一度 1 になったら 0 に戻らない。上位の非同期リセットに
//                                               つながるので、state から組み合わせ回路で作らない (一瞬の 0 がリセットになるため)
//
//   (SDRAM 側)
//   inout  wire [15:0] sdram_dq
//   output reg  [12:0] sdram_addr
//   output reg  [1:0]  sdram_ba
//   output reg         sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n
//   output reg  [1:0]  sdram_dqm
//
// Contract:
//   - 1 回のライン読み出しは、fill_valid が 1 になってから fill_ready のサイクルまで。fill_valid が途中で 0 になったら、
//     その読み出しは破棄する (0 になった後にまた 1 になっても、それは新しい読み出し)
//   - 1 回の書き込みは、we が 1 になってから wready のサイクルまで
//   - 受け付けた書き込みは、次の読み出しから見える
//   - ライン読み出しと書き込みが同じサイクルに要求されたら、読み出しを先に受け付ける
//
// Reset:       rst_n は上位のリセット。受け付けている読み出しの結果を破棄する。SDRAM の初期化はやり直さない
//              (初期化は電源投入時だけ。FF の初期値から始める)
// Clock:       posedge clk
//
// Dependencies:
//   なし
//
// Testbench:
//   tb/sdram_tb.v   ahb_sdram と SDRAM のモデルにつないで確かめる
//
// Design Notes:
//   - **アドレスの割り当ては {行, バンク, 列}。**列 9 ビット、バンク 2 ビット、残りが行。
//   - **モードは、読み出しが 8 ワードのバースト、書き込みが 1 ワード** (MR の A9)。バイト単位の書き込みは DQM で行う。
//   - **待ちのサイクル数は 20 MHz (50 ns) での値。**W9825G6KH-6 は tRCD と tRP が 15 ns、tRC 60 ns、tRAS 42 ns、tWR 2 tCK。
// =============================================================

`default_nettype none

module sdram_bridge #(
    parameter ADDR_WIDTH     = 25,
    parameter INIT_CYCLES    = 4000,
    parameter REFRESH_CYCLES = 152
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  fill_valid,
    input  wire [ADDR_WIDTH-5:0] fill_line,
    output reg                   fill_ready = 1'b0,
    output reg  [127:0]          fill_data = 128'd0,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [63:0]           wdata,
    input  wire [7:0]            wmask,
    output reg                   wready = 1'b0,
    output reg                   init_done = 1'b0,

    inout  wire [15:0]           sdram_dq,
    output reg  [12:0]           sdram_addr = 13'd0,
    output reg  [1:0]            sdram_ba = 2'd0,
    output reg                   sdram_cs_n = 1'b1,
    output reg                   sdram_ras_n = 1'b1,
    output reg                   sdram_cas_n = 1'b1,
    output reg                   sdram_we_n = 1'b1,
    output reg  [1:0]            sdram_dqm = 2'b11
);
    localparam [3:0] CMD_NOP = 4'b0111, CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRITE = 4'b0100,
                     CMD_PRE = 4'b0010, CMD_REF = 4'b0001, CMD_MRS = 4'b0000;

    localparam S_POWER = 4'd0, S_PRE_ALL = 4'd1, S_INIT_REF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4, S_REF = 4'd5,
               S_RD_CMD = 4'd6, S_RD_DATA = 4'd7, S_WR_CMD = 4'd8, S_WAIT = 4'd9;

    reg [3:0]  state = S_POWER;
    reg [12:0] cnt = 13'd0;
    reg [3:0]  init_refs = 4'd0;
    reg [8:0]  refresh_timer = 9'd0;
    reg        refresh_due = 1'b0;
    reg        rd_keep = 1'b0;      // この読み出しの結果を返すか (fill_valid が途中で 0 になったら 0)
    reg [15:0] dq_out = 16'd0;
    reg        dq_oe = 1'b0;

    // 上位の 8 バイトとバイトの有効の書き込みを、1 バイトずつの書き込み (b_*) にして、下の状態の流れに渡す。20 MHz 版は速さを
    // 問わないので、今までどおり 1 バイトごとに ACT からプリチャージまで行う。wready は、全バイトを受け付けた次のサイクルに 1
    function [2:0] lowest(input [7:0] m);   // 1 のビットのうち最も下位のもの
        integer k;
        begin
            lowest = 3'd0;
            for (k = 7; k >= 0; k = k - 1) if (m[k]) lowest = k[2:0];
        end
    endfunction
    reg        b_active = 1'b0;          // 1 バイトずつ書いている途中
    reg [7:0]  b_lanes  = 8'd0;          // まだ書いていないバイト
    reg        b_ready  = 1'b0;          // 下の状態の流れが 1 バイトを受け付けた次のサイクルに 1
    wire [2:0] b_lane   = lowest(b_lanes);
    wire                  b_we   = b_active;
    wire [ADDR_WIDTH-1:0] b_addr = {waddr[ADDR_WIDTH-1:3], b_lane};
    wire [7:0]            b_data = wdata[8 * b_lane +: 8];
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_waddr = &{1'b0, waddr[2:0]};   // 8 バイト境界なので、下位 3 ビットは見ない
    /* verilator lint_on UNUSEDSIGNAL */
    always @(posedge clk) begin
        wready <= 1'b0;
        if (!rst_n) begin
            b_active <= 1'b0;
            b_lanes  <= 8'd0;
        end else if (!b_active) begin
            // wready のサイクルは、上位が we を下げる前なので、受け付けない
            if (we && !wready) begin
                b_active <= 1'b1;
                b_lanes  <= wmask;
            end
        end else if (b_ready) begin
            if ((b_lanes & ~(8'd1 << b_lane)) == 8'd0) begin
                b_active <= 1'b0;
                b_lanes  <= 8'd0;
                wready   <= 1'b1;
            end else begin
                b_lanes  <= b_lanes & ~(8'd1 << b_lane);
            end
        end
    end

    // ワードアドレス (バイトアドレスの上位) を {行, バンク, 列} に分ける
    wire [ADDR_WIDTH-2:0] w_word = b_addr[ADDR_WIDTH-1:1];
    wire [ADDR_WIDTH-2:0] r_word = {fill_line, 3'b000};
    localparam ROW_BITS = ADDR_WIDTH - 1 - 11;
    // 行アドレスを 13 ビットに詰める (ADDR_WIDTH が 25 のときは ROW_BITS が 13 になり、0 回の繰り返しは書けないので、
    // いったん 0 にしてから下位に入れる)
    function [12:0] pad_row(input [ROW_BITS-1:0] r);
        begin
            pad_row = 13'd0;
            pad_row[ROW_BITS-1:0] = r;
        end
    endfunction

    reg [8:0]  col_q = 9'd0;
    reg [1:0]  ba_q = 2'd0;
    reg [1:0]  wmask_q = 2'b00;

    assign sdram_dq  = dq_oe ? dq_out : 16'hzzzz;

    task cmd(input [3:0] c);
        begin
            {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
        end
    endtask

    always @(posedge clk) begin
        if (state == S_IDLE) init_done <= 1'b1;

        cmd(CMD_NOP);
        fill_ready <= 1'b0;
        b_ready <= 1'b0;
        dq_oe <= 1'b0;
        sdram_dqm <= 2'b00;

        if (refresh_timer == REFRESH_CYCLES - 1) begin
            refresh_timer <= 9'd0;
            refresh_due <= init_done;
        end else
            refresh_timer <= refresh_timer + 1'b1;

        if (!fill_valid || !rst_n) rd_keep <= 1'b0;

        case (state)
            S_POWER: begin
                sdram_dqm <= 2'b11;
                cnt <= cnt + 1'b1;
                if (cnt == INIT_CYCLES - 1) begin
                    cnt <= 13'd0;
                    state <= S_PRE_ALL;
                end
            end
            S_PRE_ALL: begin
                sdram_dqm <= 2'b11;
                cmd(CMD_PRE);
                sdram_addr[10] <= 1'b1;     // 全バンク
                state <= S_INIT_REF;
                cnt <= 13'd0;
            end
            // 待ちを含めて 3 サイクルに 1 回 (tRP と tRFC は、1 サイクル 50 ns が 2 つで足りる)
            S_INIT_REF: begin
                sdram_dqm <= 2'b11;
                cnt <= cnt + 1'b1;
                if (cnt == 13'd2) begin
                    cnt <= 13'd0;
                    cmd(CMD_REF);
                    init_refs <= init_refs + 1'b1;
                    if (init_refs == 4'd8) begin
                        cmd(CMD_NOP);
                        state <= S_MRS;
                    end
                end
            end
            S_MRS: begin
                sdram_dqm <= 2'b11;
                cmd(CMD_MRS);
                sdram_ba <= 2'd0;
                sdram_addr <= 13'b000_1_00_010_0_011;   // 書き込みは 1 ワード、CL = 2、シーケンシャル、読み出しは BL = 8
                cnt <= 13'd0;
                state <= S_WAIT;
            end
            S_IDLE:
                if (refresh_due) begin
                    cmd(CMD_REF);
                    refresh_due <= 1'b0;
                    cnt <= 13'd0;
                    state <= S_REF;
                end else if (fill_valid && rst_n) begin
                    cmd(CMD_ACT);
                    sdram_ba <= r_word[10:9];
                    sdram_addr <= pad_row(r_word[ADDR_WIDTH-2:11]);
                    col_q <= r_word[8:0];
                    ba_q <= r_word[10:9];
                    rd_keep <= 1'b1;
                    state <= S_RD_CMD;
                end else if (b_we && rst_n) begin
                    cmd(CMD_ACT);
                    sdram_ba <= w_word[10:9];
                    sdram_addr <= pad_row(w_word[ADDR_WIDTH-2:11]);
                    col_q <= w_word[8:0];
                    ba_q <= w_word[10:9];
                    dq_out <= {b_data, b_data};
                    sdram_dqm <= 2'b00;
                    // アドレスの小さいバイトが下位 (DQ[7:0])。DQM が 1 のバイトは書き込まない
                    b_ready <= 1'b1;
                    state <= S_WR_CMD;
                end
            S_REF: begin                        // tRC 60 ns (2 サイクル)
                state <= S_WAIT;
                cnt <= 13'd0;
            end
            S_RD_CMD: begin
                cmd(CMD_READ);
                sdram_ba <= ba_q;
                sdram_addr <= {3'b001, 1'b0, col_q};    // A10 = オートプリチャージ
                cnt <= 13'd0;
                state <= S_RD_DATA;
            end
            // READ を出したエッジを 0 として、2 つ目のエッジで最初のワードを取り込み、そこから 8 ワード
            S_RD_DATA: begin
                cnt <= cnt + 1'b1;
                if (cnt >= 13'd1) fill_data <= {sdram_dq, fill_data[127:16]};
                if (cnt == 13'd8) begin
                    fill_ready <= rd_keep && fill_valid && rst_n;
                    rd_keep <= 1'b0;
                    cnt <= 13'd0;
                    state <= S_WAIT;
                end
            end
            S_WR_CMD: begin
                cmd(CMD_WRITE);
                sdram_ba <= ba_q;
                sdram_addr <= {3'b001, 1'b0, col_q};
                dq_oe <= 1'b1;
                sdram_dqm <= wmask_q;
                cnt <= 13'd0;
                state <= S_WAIT;
            end
            // 書き込みは tWR 2 tCK と tRP、読み出しはオートプリチャージ、リフレッシュと MRS は tRC と tMRD
            S_WAIT: begin
                cnt <= cnt + 1'b1;
                if (cnt == 13'd2) state <= S_IDLE;
            end
            default: state <= S_POWER;
        endcase
    end

    // 書き込むバイトの選択は、ACT のサイクルの b_addr で決まる
    always @(posedge clk)
        if (state == S_IDLE) wmask_q <= b_addr[0] ? 2'b01 : 2'b10;
endmodule

`default_nettype wire
