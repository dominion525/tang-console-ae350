// =============================================================
// File:        ae350/rtl/sdram_ctrl_hs.v
// Module:      sdram_ctrl_hs
// Role:        SDR SDRAM (= W9825G6KH-6) の制御の 166.7 MHz 版 (= 2026-11-11)。Lapidary の rtl/sdram_bridge.v (= 20 MHz 版) を
//              写して元にし、166.7 MHz で動くように変えたもの。上の側の口 (= fill_* / we / waddr / wdata / wready /
//              init_done) は sdram_bridge と同じなので、ahb_sdram からはどちらも同じに使える。
//              行の読みは 8 語のバースト、書きは 1 語。どちらも auto precharge。初期化とリフレッシュもここで行う。
//
//   sdram_bridge から変えたこと
//     - ピンは直接駆動せず、sdram_io (= IO の中のレジスタ) に命令、番地、DQM、DQ と出力の許可を渡し、取った DQ を受ける
//     - CL 3 (= 166.7 MHz は CL 2 の最短の周期 7.5 ns より短い)
//     - 待ちの数、初期化、リフレッシュの間隔を、クロックの周期 (= CLK_PS) から計算する
//     - ACT から次の ACT まで tRC を数えて守る
//     - 読んだ語を取る位置を、sdram_io の遅れを足したパラメータ RD_FIRST にする
//
//   読んだ語を取る位置 (= RD_FIRST の既定の 11 の根拠。READ を io_cmd に入れた縁を k とする):
//     sdram_io の ODDR が縁 k + 1 で取り、縁 k + 3 でピンに出す。SDRAM は反転したクロックで k + 3.5 に受ける。
//     CL 3 なので、最初の語は、受けた縁から 2 つ目の縁 (= k + 5.5) の tAC (= 5 ns) 後の k + 6.33 から、
//     3 つ目の縁 + tOH の k + 7.0 まで出ている (= ボードの遅れが 0 のとき)。
//     sdram_io は IODELAY で遅らせてから、s_clk の立ち上がり (= k + 7) で取り、IDDR の 2 段と受けの 1 段を経て、
//     この回路が縁 k + 11 で dq_s に受ける。cnt が RD_FIRST のときの縁で、dq_s に最初の語がある。
//     立ち下がり (= k + 6.5) で取る場合は、IDDR の中が 1 段短いので 10 (= 2026-11-11 にシミュレーションで確かめる)
//
// Parameters:
//   ADDR_WIDTH   byte 番地の幅 (= 25 で 32 MB)
//   CLK_PS       クロックの周期 (ps、既定 6000 = 166.7 MHz)
//   RD_FIRST     READ を出してから、dq_s に最初の語が来る縁までの cnt の値 (= 上の計算)
// =============================================================

`default_nettype none

module sdram_ctrl_hs #(
    parameter integer ADDR_WIDTH = 25,
    parameter integer CLK_PS     = 6000,
    parameter integer RD_FIRST   = 11
) (
    input  wire                  clk,          // s_clk
    input  wire                  rst_n,
    input  wire                  fill_valid,
    input  wire [ADDR_WIDTH-5:0] fill_line,
    output reg                   fill_ready,
    output reg  [127:0]          fill_data,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [7:0]            wdata,
    output reg                   wready,
    output reg                   init_done,

    // sdram_io へ
    output reg  [3:0]            io_cmd,       // {cs_n, ras_n, cas_n, we_n}
    output reg  [12:0]           io_addr,
    output reg  [1:0]            io_ba,
    output reg  [1:0]            io_dqm,
    output reg  [15:0]           io_dq_out,
    output reg                   io_dq_oe,
    input  wire [15:0]           io_dq_in      // c_clk の側 (= sdram_io の受けのレジスタ)
);
    // 待ちの数 (= ns をクロックの周期で割って切り上げ)
    function integer cyc(input integer ps);
        cyc = (ps + CLK_PS - 1) / CLK_PS;
    endfunction
    localparam integer T_RCD   = cyc(15000);           // ACT → READ / WRITE
    localparam integer T_RP    = cyc(15000);           // PRECHARGE → ACT
    localparam integer T_RC    = cyc(60000);           // ACT → ACT
    localparam integer T_RFC   = cyc(60000);           // REF → 次の命令
    localparam integer T_WR    = 2;                    // 書いた語 → PRECHARGE (= 2 tCK)
    localparam integer T_RAS   = cyc(42000);           // ACT → PRECHARGE
    // WRITE を出す位置 (= ACT から)。auto precharge は WRITE の tWR 後に始まるので、tRAS も守る
    localparam integer T_WR_AT = (T_RAS - T_WR > T_RCD) ? (T_RAS - T_WR) : T_RCD;
    localparam integer T_MRD   = 2;
    localparam integer INIT_CYCLES    = cyc(200000000);  // 電源投入の後の待ち (= 200 µs)
    localparam integer REFRESH_CYCLES = 7600000 / CLK_PS; // リフレッシュの間隔 (= 7.6 µs。64 ms / 8192 = 7.8 µs より短く)

    // カウンタの幅は、数える最大の値から決める (= 2026-11-13。初期化の 200 µs に合わせて 16 bit で数えていたため、
    // どの状態でも 16 bit の比べる回路が並び、166.7 MHz で s_clk の経路が収まらなかった)
    //   cnt          状態の中のクロック数 (= 初期化の後。最大は READ から最後の語までの RD_FIRST + 7 か、tRFC)
    //   init_cnt     電源投入の後の待ち (= 200 µs。S_POWER でだけ数える)
    //   since_act    最後の ACT からのクロック数 (= tRC まで数えられれば足りる。上限で止める)
    //   refresh_timer リフレッシュの間隔
    function integer max2(input integer a, input integer b);
        max2 = (a > b) ? a : b;
    endfunction
    localparam integer CNT_MAX = max2(max2(RD_FIRST + 7, T_RFC), max2(max2(T_WR_AT, T_RCD), max2(T_WR + T_RP, T_MRD)));
    localparam integer CW  = $clog2(CNT_MAX + 2);
    localparam integer IW  = $clog2(INIT_CYCLES + 1);
    localparam integer SAW = $clog2(T_RC + 1);
    localparam integer RW  = $clog2(REFRESH_CYCLES + 1);
    localparam integer RD_LAST = RD_FIRST + 7;                 // 8 語目が dq_s にある縁の cnt
    localparam [CW-1:0] RD_LAST_C  = RD_LAST[CW-1:0];
    // 1 クロック前に決めておく判断の、決めるときの cnt の値 (= 2026-11-13。判断の結果を、読んだ 16 byte の 128 個のレジスタや
    // 番地のレジスタに配る配線が長く、配置しだいで s_clk の余裕が無くなった。判断を前のクロックに済ませ、配る線を
    // レジスタから始める)。tRCD と WRITE を出す位置は 2 クロック以上であること (= 166.7 MHz では 3 と 5)
    localparam integer  SHIFT_LO   = RD_FIRST - 1;
    localparam integer  SHIFT_HI   = RD_LAST - 1;
    localparam integer  RD_GO      = T_RCD - 2;
    localparam integer  WR_GO      = T_WR_AT - 2;
    localparam [CW-1:0] SHIFT_LO_C = SHIFT_LO[CW-1:0];
    localparam [CW-1:0] SHIFT_HI_C = SHIFT_HI[CW-1:0];
    localparam [CW-1:0] RD_GO_C    = RD_GO[CW-1:0];
    localparam [CW-1:0] WR_GO_C    = WR_GO[CW-1:0];

    localparam [3:0] CMD_NOP = 4'b0111, CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRITE = 4'b0100,
                     CMD_PRE = 4'b0010, CMD_REF = 4'b0001, CMD_MRS = 4'b0000;

    // 状態の番号は sdram_bridge と同じ (= 5 は sdram_bridge の S_REF。ここではリフレッシュも S_WAIT で待つので使わない)
    localparam S_POWER = 4'd0, S_PRE_ALL = 4'd1, S_INIT_REF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4,
               S_RD_CMD = 4'd6, S_RD_DATA = 4'd7, S_WR_CMD = 4'd8, S_WAIT = 4'd9;

    reg [3:0]  state;
    reg [CW-1:0]  cnt;
    reg [IW-1:0]  init_cnt;
    reg [CW-1:0]  wait_n;        // S_WAIT で待つ数
    reg [3:0]  init_refs;
    reg [RW-1:0]  refresh_timer;
    reg        refresh_due;
    reg        rd_keep;          // この読みの結果を返すか (= fill_valid が途中で下りたら 0)
    reg [SAW-1:0] since_act;     // 最後の ACT からの縁の数 (= tRC を守る。上限で止める)
    reg [15:0] dq_s;             // 取った DQ を s_clk で受ける
    // rst_n をこの回路の中で 1 段受けてから、受けるかどうかの条件に使う (= 2026-11-13。頂点で揃えたリセットの線を、
    // そのまま読みや書きの受けの条件に使うと、引き回しの配線の遅れで s_clk の余裕がほとんど無かった)。
    // リセットが効き始めるのと解けるのが、1 クロック遅れるだけ
    reg        rst_q;
    reg        rd_shift;         // 次のクロックで、読んだ語を fill_data に取り込む
    reg        rd_go;            // 次のクロックで、READ を出す
    reg        wr_go;            // 次のクロックで、WRITE を出す

    // 語番地 (= byte 番地の上位) を {行, バンク, 列} に分ける (= sdram_bridge と同じ割り振り)
    wire [ADDR_WIDTH-2:0] w_word = waddr[ADDR_WIDTH-1:1];
    wire [ADDR_WIDTH-2:0] r_word = {fill_line, 3'b000};
    localparam ROW_BITS = ADDR_WIDTH - 1 - 11;
    function [12:0] pad_row(input [ROW_BITS-1:0] r);
        begin
            pad_row = 13'd0;
            pad_row[ROW_BITS-1:0] = r;
        end
    endfunction

    reg [8:0]  col_q;
    reg [1:0]  ba_q;
    reg [1:0]  wmask_q;

    wire act_ok = (since_act >= T_RC[SAW-1:0]);

    task cmd(input [3:0] c);
        begin
            io_cmd <= c;
        end
    endtask

    initial begin
        state = S_POWER; cnt = {CW{1'b0}}; init_cnt = {IW{1'b0}}; wait_n = {CW{1'b0}}; init_refs = 4'd0;
        refresh_timer = {RW{1'b0}}; refresh_due = 1'b0;
        rst_q = 1'b0; rd_shift = 1'b0; rd_go = 1'b0; wr_go = 1'b0; rd_keep = 1'b0; since_act = {SAW{1'b1}}; dq_s = 16'd0; col_q = 9'd0; ba_q = 2'd0; wmask_q = 2'b00;
        fill_ready = 1'b0; fill_data = 128'd0; wready = 1'b0; init_done = 1'b0;
        io_cmd = CMD_NOP; io_addr = 13'd0; io_ba = 2'd0; io_dqm = 2'b11; io_dq_out = 16'd0; io_dq_oe = 1'b0;
    end

    always @(posedge clk) begin
        dq_s  <= io_dq_in;
        rst_q <= rst_n;

        // 1 クロック前に決めておく判断 (= cnt は、この 3 つの状態では毎クロック 1 つ進む)
        rd_shift <= (state == S_RD_DATA) && (cnt >= SHIFT_LO_C) && (cnt <= SHIFT_HI_C);
        rd_go    <= (state == S_RD_CMD) && (cnt == RD_GO_C);
        wr_go    <= (state == S_WR_CMD) && (cnt == WR_GO_C);
        if (rd_shift) fill_data <= {dq_s, fill_data[127:16]};
        if (state == S_IDLE) init_done <= 1'b1;
        if (since_act != {SAW{1'b1}}) since_act <= since_act + 1'b1;

        cmd(CMD_NOP);
        fill_ready <= 1'b0;
        wready     <= 1'b0;
        io_dq_oe   <= 1'b0;
        io_dqm     <= 2'b00;

        if (refresh_timer == REFRESH_CYCLES[RW-1:0] - 1'b1) begin
            refresh_timer <= {RW{1'b0}};
            refresh_due   <= init_done;
        end else begin
            refresh_timer <= refresh_timer + 1'b1;
        end

        if (!fill_valid || !rst_q) rd_keep <= 1'b0;

        case (state)
            S_POWER: begin
                io_dqm <= 2'b11;
                init_cnt <= init_cnt + 1'b1;
                if (init_cnt == INIT_CYCLES[IW-1:0] - 1'b1) begin
                    state <= S_PRE_ALL;
                end
            end
            S_PRE_ALL: begin
                io_dqm      <= 2'b11;
                cmd(CMD_PRE);
                io_addr[10] <= 1'b1;        // 全部のバンク
                state       <= S_INIT_REF;
                cnt         <= {CW{1'b0}};
            end
            // tRP の後、tRFC おきに REF を 8 回
            S_INIT_REF: begin
                io_dqm <= 2'b11;
                cnt    <= cnt + 1'b1;
                if (cnt == T_RFC[CW-1:0]) begin
                    cnt <= {CW{1'b0}};
                    cmd(CMD_REF);
                    init_refs <= init_refs + 4'd1;
                    if (init_refs == 4'd8) begin
                        cmd(CMD_NOP);
                        state <= S_MRS;
                    end
                end
            end
            S_MRS: begin
                io_dqm  <= 2'b11;
                cmd(CMD_MRS);
                io_ba   <= 2'd0;
                io_addr <= 13'b000_1_00_011_0_011;   // 書きは 1 語、CL = 3、順次、読みは BL = 8
                cnt     <= {CW{1'b0}};
                wait_n  <= T_MRD[CW-1:0];
                state   <= S_WAIT;
            end
            S_IDLE:
                if (refresh_due) begin
                    cmd(CMD_REF);
                    refresh_due <= 1'b0;
                    cnt         <= {CW{1'b0}};
                    wait_n      <= T_RFC[CW-1:0];
                    state       <= S_WAIT;
                end else if (fill_valid && rst_q && act_ok) begin
                    cmd(CMD_ACT);
                    io_ba     <= r_word[10:9];
                    io_addr   <= pad_row(r_word[ADDR_WIDTH-2:11]);
                    col_q     <= r_word[8:0];
                    ba_q      <= r_word[10:9];
                    rd_keep   <= 1'b1;
                    since_act <= {{(SAW-1){1'b0}}, 1'b1};
                    cnt       <= {CW{1'b0}};
                    state     <= S_RD_CMD;
                end else if (we && rst_q && act_ok) begin
                    cmd(CMD_ACT);
                    io_ba     <= w_word[10:9];
                    io_addr   <= pad_row(w_word[ADDR_WIDTH-2:11]);
                    col_q     <= w_word[8:0];
                    ba_q      <= w_word[10:9];
                    io_dq_out <= {wdata, wdata};
                    // 番地の小さい byte が下位 (= DQ[7:0])。DQM が 1 の byte は書かない
                    wready    <= 1'b1;
                    since_act <= {{(SAW-1){1'b0}}, 1'b1};
                    cnt       <= {CW{1'b0}};
                    state     <= S_WR_CMD;
                end
            // ACT から tRCD を待って READ
            S_RD_CMD: begin
                cnt <= cnt + 1'b1;
                if (rd_go) begin
                    cmd(CMD_READ);
                    io_ba   <= ba_q;
                    io_addr <= {3'b001, 1'b0, col_q};    // A10 = auto precharge
                    cnt     <= {CW{1'b0}};
                    state   <= S_RD_DATA;
                end
            end
            // READ を出した縁から数えて、cnt が RD_FIRST の縁で最初の語が dq_s にある。そこから 8 語
            S_RD_DATA: begin
                cnt <= cnt + 1'b1;
                if (cnt == RD_LAST_C) begin
                    fill_ready <= rd_keep && fill_valid && rst_q;
                    rd_keep    <= 1'b0;
                    cnt        <= {CW{1'b0}};
                    wait_n     <= T_RP[CW-1:0];            // auto precharge の tRP
                    state      <= S_WAIT;
                end
            end
            // ACT から T_WR_AT (= tRCD と tRAS - tWR の大きい方) を待って WRITE (= 書く値と DQM も同じ縁で出す)
            S_WR_CMD: begin
                cnt <= cnt + 1'b1;
                if (wr_go) begin
                    cmd(CMD_WRITE);
                    io_ba    <= ba_q;
                    io_addr  <= {3'b001, 1'b0, col_q};
                    io_dq_oe <= 1'b1;
                    io_dqm   <= wmask_q;
                    cnt      <= {CW{1'b0}};
                    wait_n   <= T_WR[CW-1:0] + T_RP[CW-1:0];   // tWR と auto precharge の tRP
                    state    <= S_WAIT;
                end
            end
            S_WAIT: begin
                cnt <= cnt + 1'b1;
                if (cnt + 1'b1 >= wait_n) state <= S_IDLE;
            end
            default: state <= S_POWER;
        endcase
    end

    // 書く byte の選び方は、ACT の縁の waddr で決まる (= sdram_bridge と同じ)
    always @(posedge clk)
        if (state == S_IDLE) wmask_q <= waddr[0] ? 2'b01 : 2'b10;

endmodule

`default_nettype wire
