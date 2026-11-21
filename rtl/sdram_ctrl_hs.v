// =============================================================
// File:        rtl/sdram_ctrl_hs.v
// Module:      sdram_ctrl_hs
// Role:        SDR SDRAM (W9825G6KH-6) のコントローラ (166.7 MHz)。上位側のポート (fill_*、we、waddr、wdata、wmask、wready、
//              init_done) で ahb_sdram につなぐ。以前の 20 MHz で動くコントローラ (sdram_bridge。削除した) を元に、166.7 MHz で
//              動くように変更したもの。
//              ライン読み出しは 8 ワードのバースト。書き込みは、8 バイト (4 ワード) を、行を 1 回開いたまま、1 ワードずつの WRITE で
//              4 回続けて書く (バイトの有効 (wmask) が 0 のバイトは DQM で外す)。どちらもオートプリチャージ付き。初期化とリフレッシュも
//              ここで行う。
//              表示用の読み出しのポート (dr_*) は、指定したアドレスから指定した長さを、1 クロックに 1 ワードずつアドレスの順に返す。
//
//   表示用の読み出し (dr_*)
//     - dr_start (1 クロックのパルス) で dr_addr (16 バイト単位) から dr_bursts (16 バイト単位、1 以上) を読む。dr_busy が 1 の間の
//       dr_start は無視する。読めたワードを dr_wvalid と dr_wdata で順に出し、最後のワードと同じクロックで dr_done を 1 にする
//     - SDRAM の行 (1 バンクの 1 行 = 512 ワード) ごとに、ACT の tRCD 後から READ (BL 8) を 8 クロックごとに続けて出す (データが
//       途切れずに続く)。行の最後の READ はオートプリチャージ付き。16 バイト単位なので、8 ワードのバーストが行をまたぐことはない
//     - 1 つの行の分を出し終えたら S_IDLE に戻り、次の行の分は改めて調停を通す (行の切れ目でリフレッシュを挟めるように。
//       1 ラインの読み出しはリフレッシュの間隔より長い)
//     - 調停の順位 (S_IDLE): リフレッシュ > 表示の読み出し > CPU の読み出し > CPU の書き込み。表示の読み出しが残っている間、
//       CPU は待つ
//     - 返すワードは、READ を出したエッジから RD_FIRST の位置に印を送るシフトレジスタ (dr_mk) で数える (CPU の読み出しの
//       rd_shift と同じタイミング)。コマンドを出す側とは独立なので、次の行の ACT とデータの返却が重なってもよい
//
//   元にした 20 MHz のコントローラ (sdram_bridge) からの変更点
//     - ピンを直接駆動せず、sdram_io (IO 内のレジスタ) にコマンド、アドレス、DQM、DQ と出力許可を渡し、取り込んだ DQ を受け取る
//     - CL 3 (166.7 MHz の周期は、CL 2 の最小周期 7.5 ns より短いため)
//     - 待ちのサイクル数、初期化とリフレッシュの間隔を、クロックの周期 (CLK_PS) から計算する
//     - ACT から次の ACT まで、tRC を数えて守る
//     - 読み出しワードを取り込むタイミングを、sdram_io の遅延を加えたパラメータ RD_FIRST にする
//
//   読み出しワードを取り込むタイミング (RD_FIRST の既定値 11 の根拠。READ を io_cmd に入れたエッジを k とする):
//     sdram_io の ODDR がエッジ k + 1 で取り込み、エッジ k + 3 でピンに出す。SDRAM は反転したクロックで k + 3.5 に取り込む。
//     CL 3 なので、最初のワードは、取り込んだエッジから 2 つ目のエッジ (k + 5.5) の tAC (5 ns) 後の k + 6.33 から、
//     3 つ目のエッジ + tOH の k + 7.0 まで出力されている (ボード上の遅延が 0 の場合)。
//     sdram_io は IODELAY で遅らせてから s_clk の立ち上がり (k + 7) で取り込み、IDDR の 2 段と受けの 1 段を経て、
//     この回路がエッジ k + 11 で dq_s に受ける。cnt が RD_FIRST のときのエッジで、dq_s に最初のワードがある。
//     立ち下がり (k + 6.5) で取り込む場合は、IDDR の内部が 1 段短いので 10 になる (シミュレーションで確かめる値)
//
// Parameters:
//   ADDR_WIDTH   バイトアドレスの幅 (25 で 32 MB)
//   CLK_PS       クロックの周期 (ps、既定値 6000 = 166.7 MHz)
//   RD_FIRST     READ を出してから、dq_s に最初のワードが届くエッジまでの cnt の値 (上の計算による)
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
    input  wire [ADDR_WIDTH-1:0] waddr,        // 8 バイト境界 (下位 3 ビットは見ない)
    input  wire [63:0]           wdata,
    input  wire [7:0]            wmask,        // 書き込むバイト (1 のバイトだけ書き込む。1 つ以上が 1 であること)
    output reg                   wready,
    output reg                   init_done,

    // 表示用の読み出し
    input  wire                  dr_start,
    input  wire [ADDR_WIDTH-5:0] dr_addr,      // 16 バイト単位
    input  wire [ADDR_WIDTH-5:0] dr_bursts,    // 16 バイト単位 (1 以上)
    output reg                   dr_busy,
    output reg                   dr_wvalid,
    output reg  [15:0]           dr_wdata,
    output reg                   dr_done,

    // sdram_io へ
    output reg  [3:0]            io_cmd,       // {cs_n, ras_n, cas_n, we_n}
    output reg  [12:0]           io_addr,
    output reg  [1:0]            io_ba,
    output reg  [1:0]            io_dqm,
    output reg  [15:0]           io_dq_out,
    output reg                   io_dq_oe,
    input  wire [15:0]           io_dq_in      // c_clk 側 (sdram_io の受けのレジスタ)
);
    // 待ちのサイクル数 (ns をクロックの周期で割り、切り上げる)
    function integer cyc(input integer ps);
        cyc = (ps + CLK_PS - 1) / CLK_PS;
    endfunction
    localparam integer T_RCD   = cyc(15000);           // ACT → READ / WRITE
    localparam integer T_RP    = cyc(15000);           // PRECHARGE → ACT
    localparam integer T_RC    = cyc(60000);           // ACT → ACT
    localparam integer T_RFC   = cyc(60000);           // REF → 次の命令
    localparam integer T_WR    = 2;                    // 書き込んだワード → PRECHARGE (2 tCK)
    localparam integer T_RAS   = cyc(42000);           // ACT → PRECHARGE
    // WRITE を出すタイミング (ACT から数える)。オートプリチャージは WRITE の tWR 後に始まるので、tRAS も守る
    localparam integer T_WR_AT = (T_RAS - T_WR > T_RCD) ? (T_RAS - T_WR) : T_RCD;
    localparam integer T_MRD   = 2;
    localparam integer INIT_CYCLES    = cyc(200000000);  // 電源投入後の待ち時間 (200 µs)
    localparam integer REFRESH_CYCLES = 7600000 / CLK_PS; // リフレッシュの間隔 (7.6 µs。64 ms / 8192 = 7.8 µs より短くする)

    // カウンタの幅は、数える最大値から決める (初期化の 200 µs に合わせて 16 ビットで数えていたときは、どの状態でも
    // 16 ビットの比較回路が並び、166.7 MHz で s_clk の経路がタイミングを満たさなかった)
    //   cnt          状態の中のクロック数 (初期化の後。最大は READ から最後のワードまでの RD_FIRST + 7 か、tRFC)
    //   init_cnt     電源投入後の待ち時間 (200 µs。S_POWER でだけ数える)
    //   since_act    最後の ACT からのクロック数 (tRC まで数えられれば足りる。上限で止める)
    //   refresh_timer リフレッシュの間隔
    function integer max2(input integer a, input integer b);
        max2 = (a > b) ? a : b;
    endfunction
    localparam integer CNT_MAX = max2(max2(RD_FIRST + 7, T_RFC), max2(max2(T_WR_AT, T_RCD), max2(T_WR + T_RP, max2(T_MRD, 8 + T_RP))));
    localparam integer CW  = $clog2(CNT_MAX + 2);
    localparam integer IW  = $clog2(INIT_CYCLES + 1);
    localparam integer SAW = $clog2(T_RC + 1);
    localparam integer RW  = $clog2(REFRESH_CYCLES + 1);
    localparam integer RD_LAST = RD_FIRST + 7;                 // 8 ワード目が dq_s にあるエッジの cnt
    localparam [CW-1:0] RD_LAST_C  = RD_LAST[CW-1:0];
    // 1 クロック前に決めておく判定と、判定するときの cnt の値 (判定の結果を、読み出した 16 バイト分の 128 個のレジスタや
    // アドレスのレジスタに分配する配線が長く、配置によっては s_clk のスラックがなくなったため。判定を前のクロックで済ませ、
    // 分配する配線をレジスタから始める)。tRCD と最初の WRITE を出すタイミングは 2 クロック以上であること (166.7 MHz ではどちらも 3)
    localparam integer  SHIFT_LO   = RD_FIRST - 1;
    localparam integer  SHIFT_HI   = RD_LAST - 1;
    localparam integer  RD_GO      = T_RCD - 2;
    localparam [CW-1:0] SHIFT_LO_C = SHIFT_LO[CW-1:0];
    localparam [CW-1:0] SHIFT_HI_C = SHIFT_HI[CW-1:0];
    localparam [CW-1:0] RD_GO_C    = RD_GO[CW-1:0];
    // 書き込みは、8 バイト (4 ワード) を常に 4 回の WRITE で続けて書く。最初の WRITE を出すタイミング (ACT から数える) は、
    // 最後の WRITE (オートプリチャージ付き) が T_WR_AT より前にならないように (tRAS を守る) 決め、tRCD より前にはしない
    localparam integer  WR_START   = max2(T_RCD, T_WR_AT - 3);
    localparam integer  WR4_GO     = WR_START - 2;
    localparam [CW-1:0] WR4_GO_C   = WR4_GO[CW-1:0];
    // 表示用の読み出し: 2 回目からの READ は 8 クロックごと (1 クロック前に決めるので 6)。行の最後の READ の後は、バーストの
    // 8 クロックとプリチャージの tRP を待つ
    localparam integer  DR_NEXT    = 6;
    localparam integer  DR_WAIT    = 8 + T_RP;
    localparam [CW-1:0] DR_NEXT_C  = DR_NEXT[CW-1:0];
    localparam [CW-1:0] DR_WAIT_C  = DR_WAIT[CW-1:0];

    localparam [3:0] CMD_NOP = 4'b0111, CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRITE = 4'b0100,
                     CMD_PRE = 4'b0010, CMD_REF = 4'b0001, CMD_MRS = 4'b0000;

    // 状態の番号は元にした sdram_bridge と同じ (5 は sdram_bridge の S_REF。ここではリフレッシュも S_WAIT で待つので使わない)
    localparam S_POWER = 4'd0, S_PRE_ALL = 4'd1, S_INIT_REF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4,
               S_RD_CMD = 4'd6, S_RD_DATA = 4'd7, S_WR_CMD = 4'd8, S_WAIT = 4'd9, S_DR_RD = 4'd10;

    reg [3:0]  state;
    reg [CW-1:0]  cnt;
    reg [IW-1:0]  init_cnt;
    reg [CW-1:0]  wait_n;        // S_WAIT で待つサイクル数
    reg [3:0]  init_refs;
    reg [RW-1:0]  refresh_timer;
    reg        refresh_due;
    reg        rd_keep;          // この読み出しの結果を返すか (fill_valid が途中で 0 になったら 0)
    reg [SAW-1:0] since_act;     // 最後の ACT からのエッジ数 (tRC を守る。上限で止める)
    reg [15:0] dq_s;             // 取り込んだ DQ を s_clk で受ける
    // rst_n をこの回路の中で 1 段受けてから、受け付けの条件に使う (トップで揃えたリセットの信号をそのまま読み出しや
    // 書き込みの受け付け条件に使うと、引き回しの配線遅延で s_clk のスラックがほとんどなかったため)。
    // リセットのアサートと解除が、1 クロック遅れるだけ
    reg        rst_q;
    reg        rd_shift;         // 次のクロックで、読み出したワードを fill_data に取り込む
    reg        rd_go;            // 次のクロックで、READ を出す
    reg [3:0]  wr_pend;          // これから出す WRITE (1 のビットごとに 1 回。下位のビットから、1 クロックに 1 回出す)

    // ワードアドレス (バイトアドレスの上位) を {行, バンク, 列} に分ける
    wire [ADDR_WIDTH-2:0] w_word = waddr[ADDR_WIDTH-1:1];
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_waddr = &{1'b0, waddr[0], w_word[1:0]};   // 8 バイト境界なので、下位 3 ビット (w_word の下位 2 ビット) は見ない
    /* verilator lint_on UNUSEDSIGNAL */
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
    // 書き込み: ACT のエッジで 8 バイトとバイトの有効を受け取り、WRITE を 1 回出すたびに 16 ビット (2 バイト) ずつずらす。
    // いつも下位の 16 ビットを出すので、何番目のワードかでデータを選ぶ回路が要らない
    reg [63:0] wsh;
    reg [7:0]  msh;
    reg [1:0]  wcol;             // いま書くワードの、8 バイトの中の位置

    // 表示用の読み出し
    //   dr_ptr     次に READ を出す 16 バイトの位置 ({行, バンク, 列の上位 6 ビット})
    //   dr_left    これから READ を出すバーストの数
    //   dr_pend    READ を出していないバーストが残っている (S_IDLE で、次の行の分を始める)
    //   dr_first   この行で、まだ READ を出していない (最初の READ は tRCD 後、2 回目からは 8 クロックごと)
    //   dr_go      次のクロックで READ を出す (1 クロック前に決める)
    //   dr_last_q  次の READ が、この行の最後か、読み出し全体の最後 (オートプリチャージを付け、S_IDLE に戻る)
    //   dr_fin_q   次の READ が、読み出し全体の最後
    //   dr_mk      READ を出したエッジからのクロック数の印 (ビット j は j + 1 クロック前に READ を出した)。dr_ml は最後の READ の印
    localparam integer DRW = ADDR_WIDTH - 4;
    localparam integer MKW = RD_FIRST + 7;
    reg [DRW-1:0] dr_ptr, dr_left;
    reg           dr_pend, dr_first, dr_go, dr_last_q, dr_fin_q;
    reg [MKW-1:0] dr_mk, dr_ml;
    reg           dr_take, dr_take_last;   // 次のクロックで dq_s のワードを返す (そのワードが最後)

    // S_IDLE で次に何をするか (リフレッシュ、表示の読み出し、CPU の読み出し、CPU の書き込みのどれか 1 つ) と、ACT で出す行とバンク、
    // CPU の転送の列を、1 クロック前に決めておく (優先順位の判定と tRC の比較から、ACT のアドレスを 3 か所から選んで出すまでが
    // 1 クロックに収まらず、表示の回路をつないだ構成で s_clk の余裕がなくなったため)。S_IDLE のエッジでは、決めておいた値を出すだけ。
    // 判定に使う fill_valid、we は受け付けられるまで値を保ち、dr_pend、refresh_due はこの回路のレジスタなので、1 クロック前の値で
    // 決めてよい。tRC は、次のクロックで since_act が T_RC 以上になるか (since_act >= T_RC - 1) で見る (S_IDLE で ACT を出したエッジの
    // 判定は、次のクロックが S_IDLE ではないので使わない)
    localparam integer   T_RC_M1_I = T_RC - 1;
    localparam [SAW-1:0] T_RC_M1   = T_RC_M1_I[SAW-1:0];
    reg        sel_ref, sel_dr, sel_rd, sel_wr;
    reg [12:0] act_row_q;
    reg [1:0]  act_ba_q;
    reg [8:0]  nx_col;
    wire       rd_req  = fill_valid && rst_q;
    wire       wr_req  = we && rst_q;
    wire       trc_nxt = (since_act >= T_RC_M1);
    wire dr_read = (state == S_DR_RD) && dr_go;   // このクロックで表示の READ を出す (S_DR_RD の中の条件と同じ)

    task cmd(input [3:0] c);
        begin
            io_cmd <= c;
        end
    endtask

    initial begin
        state = S_POWER; cnt = {CW{1'b0}}; init_cnt = {IW{1'b0}}; wait_n = {CW{1'b0}}; init_refs = 4'd0;
        refresh_timer = {RW{1'b0}}; refresh_due = 1'b0;
        rst_q = 1'b0; rd_shift = 1'b0; rd_go = 1'b0; wr_pend = 4'd0; rd_keep = 1'b0; since_act = {SAW{1'b1}}; dq_s = 16'd0; col_q = 9'd0; ba_q = 2'd0;
        wsh = 64'd0; msh = 8'd0; wcol = 2'd0;
        sel_ref = 1'b0; sel_dr = 1'b0; sel_rd = 1'b0; sel_wr = 1'b0; act_row_q = 13'd0; act_ba_q = 2'd0; nx_col = 9'd0;
        dr_ptr = {DRW{1'b0}}; dr_left = {DRW{1'b0}}; dr_pend = 1'b0; dr_first = 1'b0; dr_go = 1'b0; dr_last_q = 1'b0; dr_fin_q = 1'b0;
        dr_mk = {MKW{1'b0}}; dr_ml = {MKW{1'b0}}; dr_take = 1'b0; dr_take_last = 1'b0;
        dr_busy = 1'b0; dr_wvalid = 1'b0; dr_wdata = 16'd0; dr_done = 1'b0;
        fill_ready = 1'b0; fill_data = 128'd0; wready = 1'b0; init_done = 1'b0;
        io_cmd = CMD_NOP; io_addr = 13'd0; io_ba = 2'd0; io_dqm = 2'b11; io_dq_out = 16'd0; io_dq_oe = 1'b0;
    end

    always @(posedge clk) begin
        dq_s  <= io_dq_in;
        rst_q <= rst_n;

        // 1 クロック前に決めておく判定 (この 3 つの状態では、cnt は毎クロック 1 つ進む)
        rd_shift <= (state == S_RD_DATA) && (cnt >= SHIFT_LO_C) && (cnt <= SHIFT_HI_C);
        rd_go    <= (state == S_RD_CMD) && (cnt == RD_GO_C);
        if (rd_shift) fill_data <= {dq_s, fill_data[127:16]};

        // 表示用の読み出し: 1 クロック前に決める判定
        dr_go     <= (state == S_DR_RD) && (cnt == (dr_first ? RD_GO_C : DR_NEXT_C));
        dr_fin_q  <= (dr_left == {{(DRW-1){1'b0}}, 1'b1});
        dr_last_q <= (dr_ptr[5:0] == 6'd63) || (dr_left == {{(DRW-1){1'b0}}, 1'b1}) || !dr_pend;
        // 返すワード: READ を出したエッジから RD_FIRST の位置で、8 ワード分 dr_take を 1 にする (CPU の読み出しの rd_shift と同じ位置)
        dr_take      <= |dr_mk[MKW-1:RD_FIRST-1];
        dr_take_last <= dr_ml[MKW-1];
        dr_wvalid    <= dr_take;
        dr_wdata     <= dq_s;
        dr_done      <= dr_take_last;
        if (dr_take_last) dr_busy <= 1'b0;
        if (dr_start && !dr_busy && rst_q) begin
            dr_busy  <= 1'b1;
            dr_pend  <= 1'b1;
            dr_ptr   <= dr_addr;
            dr_left  <= dr_bursts;
        end
        if (state == S_IDLE) init_done <= 1'b1;
        if (since_act != {SAW{1'b1}}) since_act <= since_act + 1'b1;
        // S_IDLE の判定を 1 クロック前に決める (上の sel_* の説明)
        sel_ref   <= refresh_due;
        sel_dr    <= !refresh_due && dr_pend && trc_nxt;
        sel_rd    <= !refresh_due && !dr_pend && rd_req && trc_nxt;
        sel_wr    <= !refresh_due && !dr_pend && !rd_req && wr_req && trc_nxt;
        act_row_q <= dr_pend ? pad_row(dr_ptr[DRW-1:8]) : rd_req ? pad_row(r_word[ADDR_WIDTH-2:11]) : pad_row(w_word[ADDR_WIDTH-2:11]);
        act_ba_q  <= dr_pend ? dr_ptr[7:6] : rd_req ? r_word[10:9] : w_word[10:9];
        nx_col    <= rd_req ? r_word[8:0] : {w_word[8:2], 2'b00};    // 書き込みは 8 バイト (4 ワード) の先頭の列

        cmd(CMD_NOP);
        fill_ready <= 1'b0;
        wready     <= 1'b0;
        io_dq_oe   <= 1'b0;
        io_dqm     <= 2'b00;
        // アドレスとバンクは、コマンドを出すクロックだけ意味がある (NOP のときは SDRAM が見ない)。値を保つ作りにすると、
        // 値を入れる場所 (ACT、READ、WRITE、初期化) が多いため取り込みの許可の論理が深くなり、s_clk の余裕を削っていた。
        // コマンドがないクロックは 0 にする
        io_addr    <= 13'd0;
        io_ba      <= 2'd0;

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
                io_addr[10] <= 1'b1;        // 全バンク
                state       <= S_INIT_REF;
                cnt         <= {CW{1'b0}};
            end
            // tRP の後、tRFC ごとに REF を 8 回
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
                io_addr <= 13'b000_1_00_011_0_011;   // 書き込みは 1 ワード、CL = 3、シーケンシャル、読み出しは BL = 8
                cnt     <= {CW{1'b0}};
                wait_n  <= T_MRD[CW-1:0];
                state   <= S_WAIT;
            end
            S_IDLE: begin
                // 書き込みのデータとバイトの有効、CPU の転送の列とバンクは、待っている間は毎クロック取り込む (ACT を出すエッジでも
                // 同じ値を取り込む。取り込み許可を判定の結果から外すため)
                wsh  <= wdata;
                msh  <= wmask;
                wcol <= 2'd0;
                col_q <= nx_col;
                ba_q  <= act_ba_q;
                if (sel_ref) begin
                    cmd(CMD_REF);
                    refresh_due <= 1'b0;
                    cnt         <= {CW{1'b0}};
                    wait_n      <= T_RFC[CW-1:0];
                    state       <= S_WAIT;
                end
                if (sel_dr || sel_rd || sel_wr) begin
                    cmd(CMD_ACT);
                    io_ba     <= act_ba_q;
                    io_addr   <= act_row_q;
                    since_act <= {{(SAW-1){1'b0}}, 1'b1};
                    cnt       <= {CW{1'b0}};
                end
                if (sel_dr) begin
                    dr_first <= 1'b1;
                    state    <= S_DR_RD;
                end
                if (sel_rd) begin
                    rd_keep <= 1'b1;
                    state   <= S_RD_CMD;
                end
                if (sel_wr) begin
                    wready <= 1'b1;
                    state  <= S_WR_CMD;
                end
            end
            // ACT から tRCD を待って READ
            S_RD_CMD: begin
                cnt <= cnt + 1'b1;
                if (rd_go) begin
                    cmd(CMD_READ);
                    io_ba   <= ba_q;
                    io_addr <= {3'b001, 1'b0, col_q};    // A10 = オートプリチャージ
                    cnt     <= {CW{1'b0}};
                    state   <= S_RD_DATA;
                end
            end
            // READ を出したエッジから数えて、cnt が RD_FIRST のエッジで最初のワードが dq_s にある。そこから 8 ワード
            S_RD_DATA: begin
                cnt <= cnt + 1'b1;
                if (cnt == RD_LAST_C) begin
                    fill_ready <= rd_keep && fill_valid && rst_q;
                    rd_keep    <= 1'b0;
                    cnt        <= {CW{1'b0}};
                    wait_n     <= T_RP[CW-1:0];            // オートプリチャージの tRP
                    state      <= S_WAIT;
                end
            end
            // ACT から WR_START を待って、4 回の WRITE を続けて出す (WRITE を出すのは、下の wr_pend の部分)。最後の WRITE を出す
            // エッジで S_WAIT に移り、tWR とオートプリチャージの tRP を待つ
            S_WR_CMD: begin
                cnt <= cnt + 1'b1;
                if (cnt == WR4_GO_C && wr_pend == 4'd0) wr_pend <= 4'b1111;
                if (wr_pend == 4'b0001) begin
                    cnt    <= {CW{1'b0}};
                    wait_n <= T_WR[CW-1:0] + T_RP[CW-1:0];
                    state  <= S_WAIT;
                end
            end
            // 表示用の読み出し: ACT の tRCD 後から、8 クロックごとに READ を出す。行の最後か全体の最後の READ はオートプリチャージ付きで、
            // そのエッジで S_WAIT に移り、バーストの 8 クロックとプリチャージの tRP を待つ (返すワードは dr_mk で数えるので、待たない)
            S_DR_RD: begin
                cnt <= cnt + 1'b1;
                if (dr_go) begin
                    cmd(CMD_READ);
                    io_ba    <= dr_ptr[7:6];
                    io_addr  <= {2'b00, dr_last_q, 1'b0, dr_ptr[5:0], 3'b000};   // A10 = オートプリチャージ
                    dr_first <= 1'b0;
                    dr_ptr   <= dr_ptr + 1'b1;
                    dr_left  <= dr_left - 1'b1;
                    cnt      <= {CW{1'b0}};
                    if (dr_fin_q) dr_pend <= 1'b0;
                    if (dr_last_q) begin
                        wait_n <= DR_WAIT_C;
                        state  <= S_WAIT;
                    end
                end
            end
            S_WAIT: begin
                cnt <= cnt + 1'b1;
                if (cnt + 1'b1 >= wait_n) state <= S_IDLE;
            end
            default: state <= S_POWER;
        endcase

        dr_mk <= {dr_mk[MKW-2:0], dr_read};
        dr_ml <= {dr_ml[MKW-2:0], dr_read && dr_fin_q};
        // リセットの間は、表示用の読み出しを止める (行の途中なら、次の READ を最後にして閉じる)
        if (!rst_q) begin
            dr_busy <= 1'b0;
            dr_pend <= 1'b0;
            dr_mk   <= {MKW{1'b0}};
            dr_ml   <= {MKW{1'b0}};
            dr_take <= 1'b0;
            dr_take_last <= 1'b0;
        end

        // WRITE を出す (wr_pend の最下位のビットが 1 のエッジごとに 1 回。出すかどうかはレジスタだけで決まる)。書き込む値と DQM も
        // 同じエッジで出す。アドレスの小さいバイトが下位 (DQ[7:0])。DQM が 1 のバイトは書き込まない
        if (wr_pend[0]) begin
            cmd(CMD_WRITE);
            io_ba     <= ba_q;
            io_addr   <= {2'b00, wr_pend[3:1] == 3'b000, 1'b0, col_q[8:2], wcol};   // A10 = 最後のワードならオートプリチャージ
            io_dq_oe  <= 1'b1;
            io_dq_out <= wsh[15:0];
            io_dqm    <= ~msh[1:0];
            wsh       <= {16'd0, wsh[63:16]};
            msh       <= {2'b00, msh[7:2]};
            wcol      <= wcol + 2'd1;
            wr_pend   <= {1'b0, wr_pend[3:1]};
        end
    end

endmodule

`default_nettype wire
