// =============================================================
// File:        rtl/sdram_bridge.v
// Module:      sdram_bridge
// Role:        上位の回路 (= rtl/ahb_sdram.v) からの行のポートと書きのポートを、SDR SDRAM
//              (= W9825G6KH-6) の命令に直す。行の読みは 8 語のバースト、書きは 1 語。どちらも auto precharge。
//              SDRAM の初期化とリフレッシュもここで行う。クロックは clk 1 本。
//
//              SDRAM のクロックは clk の逆相 (= 上位のトップが ~clk を出す)。命令は clk の立ち上がりで変わり、SDRAM は
//              半 cycle 後の立ち上がりで受ける。CL = 2 なので、読みの最初の語は、受けた 1 cycle 後の SDRAM の立ち上がりから
//              tAC (= 6 ns) で出て、次の立ち上がりの tOH (= 3 ns) まで保たれる。READ を出した clk の縁の 2 つ後の縁で取る。
//              20 MHz なら、ピンまでのクロックの遅れが 19 ns ほどまで取れる。
//
// Parameters:
//   ADDR_WIDTH     = 25                   byte 番地の幅 (= 32 MB。W9825G6KH の大きさ)
//   INIT_CYCLES    = 4000                 電源投入の後の待ち (= 200 us、20 MHz)
//   REFRESH_CYCLES = 152                  リフレッシュの間隔 (= 7.6 us、20 MHz)
//
// Ports:
//   (上位の回路の側)
//   input  wire clk, rst_n
//   input  wire                   fill_valid    行を読んでほしい間 1
//   input  wire [ADDR_WIDTH-5:0]  fill_line     行の番地 (= byte 番地の上位。16 byte 境界)
//   output reg                    fill_ready    行が出た cycle に 1
//   output reg  [127:0]           fill_data     行の 16 byte。番地の小さい byte が下位
//   input  wire                   we            書いてほしい間 1
//   input  wire [ADDR_WIDTH-1:0]  waddr
//   input  wire [7:0]             wdata
//   output reg                    wready        受け付けた次の cycle に 1
//   output reg                    init_done     SDRAM の初期化が終わった。一度立ったら下りない。上位の非同期 reset に
//                                               つながるので、state から組み合わせ回路で作らない (= 一瞬の 0 が reset になる)
//
//   (SDRAM の側)
//   inout  wire [15:0] sdram_dq
//   output reg  [12:0] sdram_addr
//   output reg  [1:0]  sdram_ba
//   output reg         sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n
//   output reg  [1:0]  sdram_dqm
//
// Contract:
//   - 行の読み 1 回は、fill_valid が立ってから fill_ready の cycle まで。fill_valid が途中で下りたら、
//     その読みは捨てる (= 下りた後にまた立っても、それは新しい読み)
//   - 書き 1 回は、we が立ってから wready の cycle まで
//   - 受け付けた書き込みは、次の読みから見える
//   - 行の読みと書きが同じ cycle に立っていたら、読みを先に受ける
//
// Reset:       rst_n は上位の reset。受け付けている読みの結果を捨てる。SDRAM の初期化はやり直さない
//              (= 電源投入のときだけ。FF の初期値で始める)
// Clock:       posedge clk
//
// Dependencies:
//   なし
//
// Testbench:
//   tb/sdram_tb.v   ahb_sdram と SDRAM のモデルとつないで確かめる
//
// Design Notes:
//   - **番地の割り当ては {行, バンク, 列}。**列 9 bit、バンク 2 bit、残りが行。
//   - **モードは、読みが 8 語のバースト、書きが 1 語** (= MR の A9)。byte の書き分けは DQM で行う。
//   - **待ちの cycle は 20 MHz (= 50 ns) の値。**W9825G6KH-6 は tRCD / tRP 15 ns、tRC 60 ns、tRAS 42 ns、tWR 2 tCK。
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
    input  wire [7:0]            wdata,
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
    reg        rd_keep = 1'b0;      // この読みの結果を返すか (= fill_valid が途中で下りたら 0)
    reg [15:0] dq_out = 16'd0;
    reg        dq_oe = 1'b0;

    // 語番地 (= byte 番地の上位) を {行, バンク, 列} に分ける
    wire [ADDR_WIDTH-2:0] w_word = waddr[ADDR_WIDTH-1:1];
    wire [ADDR_WIDTH-2:0] r_word = {fill_line, 3'b000};
    localparam ROW_BITS = ADDR_WIDTH - 1 - 11;
    // 行の番地を 13 bit に詰める (= ADDR_WIDTH が 25 のとき ROW_BITS が 13 になり、0 回の繰り返しは書けないので、
    // 0 にしてから下位に入れる)
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
        wready <= 1'b0;
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
                sdram_addr[10] <= 1'b1;     // 全部のバンク
                state <= S_INIT_REF;
                cnt <= 13'd0;
            end
            // 待ちを含めて 3 cycle に 1 回 (= tRP、tRFC は 1 cycle の 50 ns を 2 つで足りる)
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
                sdram_addr <= 13'b000_1_00_010_0_011;   // 書きは 1 語、CL = 2、順次、読みは BL = 8
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
                end else if (we && rst_n) begin
                    cmd(CMD_ACT);
                    sdram_ba <= w_word[10:9];
                    sdram_addr <= pad_row(w_word[ADDR_WIDTH-2:11]);
                    col_q <= w_word[8:0];
                    ba_q <= w_word[10:9];
                    dq_out <= {wdata, wdata};
                    sdram_dqm <= 2'b00;
                    // 番地の小さい byte が下位 (= DQ[7:0])。DQM が 1 の byte は書かない
                    wready <= 1'b1;
                    state <= S_WR_CMD;
                end
            S_REF: begin                        // tRC 60 ns (= 2 cycle)
                state <= S_WAIT;
                cnt <= 13'd0;
            end
            S_RD_CMD: begin
                cmd(CMD_READ);
                sdram_ba <= ba_q;
                sdram_addr <= {3'b001, 1'b0, col_q};    // A10 = auto precharge
                cnt <= 13'd0;
                state <= S_RD_DATA;
            end
            // READ を出した縁を 0 として、2 つ目の縁で最初の語を取り、そこから 8 語
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
            // 書きは tWR 2 tCK と tRP、読みは auto precharge、リフレッシュと MRS は tRC / tMRD
            S_WAIT: begin
                cnt <= cnt + 1'b1;
                if (cnt == 13'd2) state <= S_IDLE;
            end
            default: state <= S_POWER;
        endcase
    end

    // 書く byte の選び方は、ACT の cycle の waddr で決まる
    always @(posedge clk)
        if (state == S_IDLE) wmask_q <= waddr[0] ? 2'b01 : 2'b10;
endmodule

`default_nettype wire
