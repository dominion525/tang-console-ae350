/*
 * 出典: machdyne/zeitlos の rtl/tb/sdram_model.v (コミット 3242dedc733f3571f6c53108fa853c7429b8a07b)。
 * 同じディレクトリの LICENSE.md の条件 (著作権表示と免責の文を残すこと) に従い、改変して再配布する。
 *
 * 元のファイルからの変更点:
 *   - タイミングの検査: W9825G6KH-6 のデータシートの 9.5 の値で検査する
 *   - 電源投入の検査: 200 us の待ち、待ちの間の DQM、最初の全バンクのプリチャージ、8 回のリフレッシュ
 *   - 読み出しの出力: tOH から、tAC か tHZ の最大値までの間は不定値を出す
 *   - tAC、tOH、tHZ: 5 ns と 2 ns の固定値から、データシートの値に変えた。tAC と tHZ は CL ごとの値
 *   - MEM_WORDS の既定値: 65,536 ワードから 16,777,216 ワードに変えた
 *   - メモリの初期値: 0 から不定値に変えた (書き込んでいないワードを読むと分かるように)
 *
 * Behavioural SDR SDRAM model -- W9825G6KH / MT48LC16M16A2 class (x16)
 *
 * 4 banks x 8192 rows x 512 columns x 16 bits. Commands are sampled on
 * the rising edge of `clk`, which is the SDRAM's own CK pin (in this
 * SOC that is ~fabric clock, see rtl/mem/sdram_kianv.v).
 *
 * What it models:
 *   - MRS: burst length 1/2/4/8 and full page, sequential or interleaved wrap within the burst,
 *     CAS latency 2/3, and burst-write vs single-write mode (A9)
 *   - READ bursts delivered CAS_LATENCY edges after the command,
 *     driven TAC ns after the previous edge and held until TOH ns
 *     after the sampling edge -- the controller's negedge capture
 *     (READ_NEGEDGE=1) sees exactly what a real part would give it
 *   - a READ or WRITE issued during a read burst truncates it (this
 *     is what makes back-to-back BL2 READs seamless), BST terminates
 *   - WRITE bursts with DQM byte masking per beat
 *   - auto-precharge (A10) on READ/WRITE, PRE one bank / all
 *
 * What it checks (each is an error, counted in `errors`):
 *   - any command before the mode register is set, except the
 *     init sequence (NOP, PRE, REF, MRS)
 *   - ACT on a bank whose row is already open
 *   - READ/WRITE on a bank with no open row
 *   - REF while any bank is open
 *   - MRS while any bank is open
 *
 * タイミングの検査: W9825G6KH-6 のデータシート (9.5 AC Characteristics) の値で、tRC、tRAS、tRCD、tRP、tRRD、
 * tWR、tRSC、tCK、tCH、tCL、tREF、入力のセットアップとホールド、電源投入後の手順を検査する。違反は
 * "SDRAM ERROR" で始まる行に出力し、errors を増やす。
 *
 * Backing store is sparse: only the low MEM_WORDS 16-bit words of the
 * flattened {bank,row,col} space exist; anything above reads 16'hDEAD.
 *
 * This replaces an earlier, unfinished model (it returned zeros for
 * every read). tb_sdram_burst.v and tb_cache_sdram.v drive it.
 */

`timescale 1ns / 1ps

module sdram_model #(
    parameter MEM_WORDS = 16777216,  // 16-bit words backed
    // 読み出しの出力のタイミング (-6 の値)。単位は ns
    parameter real TAC_CL2 = 6.0,    // clock-to-data-valid
    parameter real TAC_CL3 = 5.0,
    parameter real THZ_CL2 = 6.0,    // ハイインピーダンスになるまでの最大値
    parameter real THZ_CL3 = 5.0,
    parameter real TOH = 3.0,        // data hold after next edge, ns
    // W9825G6KH-6 の値。単位は ns。_CK が付くものは tCK
    parameter real T_RC = 60.0,
    parameter real T_RAS = 42.0,
    parameter real T_RAS_MAX = 100000.0,
    parameter real T_RCD = 15.0,
    parameter real T_RP = 15.0,
    parameter integer T_RRD_CK = 2,
    parameter integer T_WR_CK = 2,
    parameter integer T_RSC_CK = 2,
    parameter real T_CK_CL2 = 7.5,
    parameter real T_CK_CL3 = 6.0,
    parameter real T_CK_MAX = 1000.0,
    parameter real T_CH = 2.0,
    parameter real T_CL = 2.0,
    parameter real T_DS = 1.5,
    parameter real T_DH = 0.8,
    parameter real T_AS = 1.5,
    parameter real T_AH = 0.8,
    parameter real T_CMS = 1.5,
    parameter real T_CMH = 0.8,
    parameter real T_CKS = 1.5,
    parameter real T_CKH = 0.8,
    parameter real T_INIT = 200000.0,   // 電源投入後の待ち時間
    parameter real T_REF = 64000000.0   // この時間の間に 8,192 回のリフレッシュが必要
) (
    input wire clk,
    input wire cke,
    input wire csn,
    input wire rasn,
    input wire casn,
    input wire wen,
    input wire [1:0] dqm,
    input wire [1:0] ba,
    input wire [12:0] addr,
    inout wire [15:0] dq
);

    localparam CMD_MRS     = 4'b0000;
    localparam CMD_REFRESH = 4'b0001;
    localparam CMD_PRE     = 4'b0010;
    localparam CMD_ACT     = 4'b0011;
    localparam CMD_WRITE   = 4'b0100;
    localparam CMD_READ    = 4'b0101;
    localparam CMD_BST     = 4'b0110;
    localparam CMD_NOP     = 4'b0111;

    wire [3:0] cmd = csn ? CMD_NOP : { 1'b0, rasn, casn, wen };

    reg [15:0] mem [0:MEM_WORDS-1];
    reg [12:0] open_row [0:3];
    reg        row_open [0:3];

    reg        mode_set;
    reg [3:0]  bl;                   // 1, 2, 4 or 8
    reg [2:0]  cl;
    reg        single_write;
    reg        interleave;           // A3 = 1
    reg        full_page;            // A2〜A0 = 111、シーケンシャル

    // read burst in progress (as issued; data emerges cl edges later)
    reg        rd_act;
    reg [1:0]  rd_bank;
    reg [12:0] rd_row;
    reg [8:0]  rd_col0;
    reg [9:0]  rd_beat;
    reg        rd_ap;

    // write burst in progress
    reg        wr_act;
    reg [1:0]  wr_bank;
    reg [12:0] wr_row;
    reg [8:0]  wr_col0;
    reg [9:0]  wr_beat;
    reg        wr_ap;

    // output pipeline, indexed by edges-until-sampled
    reg [15:0] pipe_d [0:7];
    reg        pipe_v [0:7];
    reg [2:0]  dqm_d1;               // read DQM has 2-edge latency
    reg [1:0]  rdqm_0;
    reg [1:0]  rdqm_1;

    reg [15:0] dq_out;
    reg        dq_oe;
    assign dq = dq_oe ? dq_out : 16'hzzzz;

    integer errors;
    integer reads;
    integer writes;
    integer i;
    reg [31:0] fa;
    reg [8:0] col;
    reg [15:0] w;
    real       t_dly;
    
    // -- タイミングの検査の状態 --------------------------------
    realtime t_act [0:3];        // ACT の時刻
    realtime t_pre [0:3];        // 内部のプリチャージが始まる時刻
    integer  e_wr  [0:3];        // 最後に書き込んだワードのエッジの番号
    realtime t_ref, t_rise, t_fall, t_first, t_ref_deadline, period;
    realtime t_wr_edge [0:1];     // バイトごとの、最後に取り込んだエッジ
    // 変化の時刻と、直前のエッジでそのピンが有効だったか (データシートの Truth Table)
    realtime t_cs_chg, t_rcw_chg, t_dqm_chg, t_a_chg, t_a10_chg, t_ba_chg;
    reg      hold_rcw, hold_dqm, hold_a, hold_a10, hold_ba;
    reg      v_a, v_a10, v_ba, dqm_on;
    realtime t_dq_chg [0:1];      // バイトごとの、DQ が変化した時刻
    realtime t_ref_ring [0:8191];   // 直近 8,192 回のリフレッシュの時刻
    integer  edge_n, e_act, e_mrs, n_ref;
    reg      pre_all_done, ras_max_rep [0:3], ref_deadline_rep, first_cmd_seen;
    // CKE は 1 クロック遅れて効く (データシートの 7.20)。clk_run が 0 のエッジでは何も進めず、コマンドを無視する
    reg      cke_prev, clk_run, cke_low_rep, pause_cke_rep;
    realtime t_cke_chg;
    reg      pause_dqm_rep, wr_ap_busy, rd_ap_busy, burst_busy;
    
    task err;
        input [8*56-1:0] msg;
    begin
        $display("SDRAM ERROR @%0t: %0s", $realtime, msg);
        errors = errors + 1;
    end
    endtask
    
    // オートプリチャージが、現在のエッジから edges 個後に始まる
    task auto_pre;
        input [1:0] b;
        input integer edges;
    begin
        t_pre[b] = $realtime + edges * period;
        if (t_pre[b] - t_act[b] < T_RAS) err("tRAS: auto precharge too early");
    end
    endtask
    
    always @(negedge clk) begin
        t_fall = $realtime;
        if (t_rise >= 0 && t_fall - t_rise < T_CH) err("tCH: clock high too short");
    end
    
    always @(cke) begin
        if (t_rise >= 0 && $realtime - t_rise < T_CKH) err("tCKH: CKE hold");
        t_cke_chg = $realtime;
    end
    always @(csn) begin
        if (t_rise >= 0 && $realtime - t_rise < T_CMH) err("tCMH: CS hold");
        t_cs_chg = $realtime;
    end
    always @(rasn or casn or wen) begin
        if (hold_rcw && $realtime - t_rise < T_CMH) err("tCMH: command hold");
        t_rcw_chg = $realtime;
    end
    always @(dqm) begin
        if (hold_dqm && $realtime - t_rise < T_CMH) err("tCMH: DQM hold");
        t_dqm_chg = $realtime;
    end
    always @(addr[9:0] or addr[12:11]) begin
        if (hold_a && $realtime - t_rise < T_AH) err("tAH: address hold");
        t_a_chg = $realtime;
    end
    always @(addr[10]) begin
        if (hold_a10 && $realtime - t_rise < T_AH) err("tAH: A10 hold");
        t_a10_chg = $realtime;
    end
    always @(ba) begin
        if (hold_ba && $realtime - t_rise < T_AH) err("tAH: bank address hold");
        t_ba_chg = $realtime;
    end
    always @(dq[7:0]) begin
        if ($realtime - t_wr_edge[0] < T_DH) err("tDH: write data hold");
        t_dq_chg[0] = $realtime;
    end
    always @(dq[15:8]) begin
        if ($realtime - t_wr_edge[1] < T_DH) err("tDH: write data hold");
        t_dq_chg[1] = $realtime;
    end
    
    // エッジごとの検査。コマンドで状態が変わる前に呼ぶ
    task check_edge;
    begin
        edge_n = edge_n + 1;
        if (edge_n == 1) t_first = $realtime;
        period = $realtime - t_rise;
        if (t_rise >= 0) begin
            // モード設定の前は CL が決まっていないので、緩い方の値で検査する
            if (period < ((cl == 3 || !mode_set) ? T_CK_CL3 : T_CK_CL2)) err("tCK: clock too fast");
            if (mode_set && period > T_CK_MAX) err("tCK: clock too slow");
        end
        if (t_fall >= 0 && $realtime - t_fall < T_CL) err("tCL: clock low too short");
        t_rise = $realtime;
    
        // コマンドごとに有効なピン (Truth Table)。CS は常に、RAS、CAS、WE は CS が Low のときに見る
        v_a   = clk_run && (cmd == CMD_ACT || cmd == CMD_READ || cmd == CMD_WRITE || cmd == CMD_MRS);
        v_a10 = v_a || (clk_run && cmd == CMD_PRE);
        v_ba  = v_a || (clk_run && cmd == CMD_PRE && addr[10] !== 1'b1);
        // DQM はデータの転送がある間だけ意味を持つ (Truth Table の Data Write/Output、10.3 の図)
        dqm_on = rd_act || wr_act;
        for (i = 0; i < 4; i = i + 1) if (row_open[i]) dqm_on = 1'b1;
        for (i = 0; i < 8; i = i + 1) if (pipe_v[i]) dqm_on = 1'b1;

        if (cke === 1'bx) err("CKE is unknown");
        if ($realtime - t_cke_chg < T_CKS) err("tCKS: CKE setup");
        // 待ちの間は CKE を High にする (データシートの 7.1)
        if (!first_cmd_seen && !pause_cke_rep && cke !== 1'b1) begin
            err("CKE must be high during the power-up pause");
            pause_cke_rep = 1'b1;
        end
        // 開いているバンクがない間の CKE Low は Power Down か Self Refresh で、このモデルは再現しない
        if (first_cmd_seen && cke === 1'b0 && !dqm_on) begin
            if (!cke_low_rep) err("CKE low with no active bank is not modelled");
            cke_low_rep = 1'b1;
        end else cke_low_rep = 1'b0;
        if (csn === 1'bx) err("CS is unknown");
        if (csn === 1'b0 && (^{rasn, casn, wen}) === 1'bx) err("command pin is unknown");
        if (dqm_on && (^dqm) === 1'bx) err("DQM is unknown");
        if (v_a && (^{addr[12:11], addr[9:0]}) === 1'bx) err("address pin is unknown");
        if (v_a10 && addr[10] === 1'bx) err("A10 is unknown");
        if (v_ba && (^ba) === 1'bx) err("bank address is unknown");

        if ($realtime - t_cs_chg < T_CMS) err("tCMS: CS setup");
        if (csn === 1'b0 && $realtime - t_rcw_chg < T_CMS) err("tCMS: command setup");
        if (dqm_on && $realtime - t_dqm_chg < T_CMS) err("tCMS: DQM setup");
        if (v_a && $realtime - t_a_chg < T_AS) err("tAS: address setup");
        if (v_a10 && $realtime - t_a10_chg < T_AS) err("tAS: A10 setup");
        if (v_ba && $realtime - t_ba_chg < T_AS) err("tAS: bank address setup");

        hold_rcw = (csn === 1'b0);
        hold_dqm = dqm_on;
        hold_a = v_a;
        hold_a10 = v_a10;
        hold_ba = v_ba;
    
        if (!first_cmd_seen && !pause_dqm_rep && dqm !== 2'b11 && cmd == CMD_NOP) begin
            err("DQM must be high during the power-up pause");
            pause_dqm_rep = 1'b1;
        end
        for (i = 0; i < 4; i = i + 1)
            if (row_open[i] && !ras_max_rep[i] && $realtime - t_act[i] > T_RAS_MAX) begin
                err("tRAS: row open too long");
                ras_max_rep[i] = 1'b1;
            end
        if (n_ref > 0 && !ref_deadline_rep && $realtime > t_ref_deadline) begin
            err("tREF: too few refreshes");
            ref_deadline_rep = 1'b1;
        end
    end
    endtask
    
    // コマンドごとの検査。継続中の読み書きの処理の後、コマンドで状態が変わる前に呼ぶ
    task check_cmd;
    begin
        if (cmd != CMD_NOP && !first_cmd_seen) begin
            first_cmd_seen = 1'b1;
            if ($realtime - t_first < T_INIT) err("power-up pause shorter than 200 us");
            if (!(cmd == CMD_PRE && addr[10])) err("first command must be precharge all");
        end
        if (cmd == CMD_PRE && addr[10]) pre_all_done = 1'b1;
        if (cmd != CMD_NOP && cmd != CMD_BST && edge_n - e_mrs < T_RSC_CK) err("tRSC: command too soon after MRS");
    
        case (cmd)
            CMD_ACT: begin
                if (!pre_all_done || !mode_set || n_ref < 8) err("ACT before the power-up sequence ends");
                if ($realtime - t_act[ba] < T_RC) err("tRC: ACT to ACT, same bank");
                if ($realtime - t_pre[ba] < T_RP) err("tRP: precharge to ACT");
                if ($realtime - t_ref < T_RC) err("tRC: refresh to ACT");
                if (edge_n - e_act < T_RRD_CK) err("tRRD: ACT to ACT");
                t_act[ba] = $realtime;
                e_act = edge_n;
                ras_max_rep[ba] = 1'b0;
            end
            CMD_READ, CMD_WRITE: begin
                if ($realtime - t_act[ba] < T_RCD) err("tRCD: ACT to read or write");
                // 読み出しを WRITE で打ち切るとき、WRITE の 1、2 クロック目に出る読み出しの値は DQM で止める
                // (データシートの 7.8)。rdqm_1 は 1 クロック目、rdqm_0 は 2 クロック目の値を止める DQM
                if (cmd == CMD_WRITE && ((dq_oe && rdqm_1 != 2'b11) || (pipe_v[0] && rdqm_0 != 2'b11)))
                    err("DQM must mask read data during a WRITE");
                // Full Page ではオートプリチャージを使えない (データシートの 7.14)
                if (full_page && addr[10]) err("auto precharge with full page");
                if ((rd_ap_busy && rd_bank == ba) || (wr_ap_busy && wr_bank == ba))
                    err("command during an auto precharge burst");
            end
            CMD_PRE:
                for (i = 0; i < 4; i = i + 1)
                    if (addr[10] || ba == i) begin
                        if (row_open[i]) begin
                            if ($realtime - t_act[i] < T_RAS) err("tRAS: ACT to precharge");
                            if (edge_n - e_wr[i] < T_WR_CK) err("tWR: write to precharge");
                            if ((rd_ap_busy && rd_bank == i) || (wr_ap_busy && wr_bank == i))
                                err("command during an auto precharge burst");
                        end
                        t_pre[i] = $realtime;
                    end
            CMD_REFRESH: begin
                for (i = 0; i < 4; i = i + 1) begin
                    if ($realtime - t_pre[i] < T_RP) err("tRP: precharge to refresh");
                    if ($realtime - t_act[i] < T_RC) err("tRC: ACT to refresh");
                end
                if ($realtime - t_ref < T_RC) err("tRC: refresh to refresh");
                t_ref = $realtime;
                t_ref_ring[n_ref % 8192] = $realtime;
                n_ref = n_ref + 1;
                // 同じ行の次のリフレッシュは 8,192 回後なので、最も古い時刻から T_REF 以内に次のリフレッシュを出す
                t_ref_deadline = t_ref_ring[(n_ref < 8192) ? 0 : n_ref % 8192] + T_REF;
            end
            // BST は Full Page のバーストだけを止める (データシートの 7.11、Truth Table)
            CMD_BST:
                if (!(full_page && burst_busy)) err("BST outside a full page burst");
            CMD_MRS: begin
                for (i = 0; i < 4; i = i + 1) begin
                    if ($realtime - t_pre[i] < T_RP) err("tRP: precharge to MRS");
                end
                if ($realtime - t_ref < T_RC) err("tRC: refresh to MRS");
                e_mrs = edge_n;
            end
            default: ;
        endcase
    end
    endtask
    
    // 書き込むワードの検査。mem に入れる前に呼ぶ
    task check_write_data;
        input [1:0] b;
    begin
        // DQM が High のバイトは取り込まない (データシートの 5 章) ので、DQM が Low のバイトだけを見る
        for (i = 0; i < 2; i = i + 1)
            if (!dqm[i]) begin
                if ($realtime - t_dq_chg[i] < T_DS) err("tDS: write data setup");
                t_wr_edge[i] = $realtime;
            end
        if ((!dqm[0] && (^dq[7:0]) === 1'bx) || (!dqm[1] && (^dq[15:8]) === 1'bx)) err("write data is unknown");
        // tWR は、1 バイトでも書き込んだワードから数える
        if (dqm != 2'b11) e_wr[b] = edge_n;
    end
    endtask

    function [31:0] flat;
        input [1:0] b;
        input [12:0] r;
        input [8:0] c;
    begin
        flat = { b, r, c };
    end
    endfunction

    // sequential wrap inside a BL-aligned block。インターリーブでは、アドレスの下位をビットごとに反転して進む (データシートの 7.13)
    function [8:0] burst_col;
        input [8:0] c0;
        input [9:0] beat;
        input [3:0] len;
    begin
        // Full Page は列の 512 ワードで一周する
        if (full_page) burst_col = c0 + beat[8:0];
        else case (len)
            4'd2: burst_col = interleave ? { c0[8:1], c0[0]   ^ beat[0]   } : { c0[8:1], c0[0]   + beat[0]   };
            4'd4: burst_col = interleave ? { c0[8:2], c0[1:0] ^ beat[1:0] } : { c0[8:2], c0[1:0] + beat[1:0] };
            4'd8: burst_col = interleave ? { c0[8:3], c0[2:0] ^ beat[2:0] } : { c0[8:3], c0[2:0] + beat[2:0] };
            default: burst_col = c0;
        endcase
    end
    endfunction

    task rd_word;
        input [31:0] a;
        output [15:0] v;
    begin
        if (a < MEM_WORDS) v = mem[a]; else v = 16'hDEAD;
    end
    endtask

    // Seed one 16-bit word of the flattened array (kept for
    // tb_cache_sdram.v; newer testbenches write mem[] directly).
    task preload;
        input [31:0] word_addr;
        input [15:0] value;
    begin
        if (word_addr < MEM_WORDS) mem[word_addr] = value;
    end
    endtask

    initial begin
        errors = 0; reads = 0; writes = 0;
        mode_set = 0; bl = 1; cl = 2; single_write = 0; interleave = 0; full_page = 0;
        rd_act = 0; wr_act = 0; wr_ap = 0; dq_oe = 0; dq_out = 0;
        rdqm_0 = 2'b11; rdqm_1 = 2'b11;
        t_ref = -1.0e9; t_rise = -1.0; t_fall = -1.0; t_first = 0; t_ref_deadline = 0; period = 0;
        t_wr_edge[0] = -1.0e9; t_wr_edge[1] = -1.0e9;
        t_cs_chg = -1.0e9; t_rcw_chg = -1.0e9; t_dqm_chg = -1.0e9; t_a_chg = -1.0e9; t_a10_chg = -1.0e9; t_ba_chg = -1.0e9;
        hold_rcw = 0; hold_dqm = 0; hold_a = 0; hold_a10 = 0; hold_ba = 0;
        t_dq_chg[0] = -1.0e9; t_dq_chg[1] = -1.0e9;
        edge_n = 0; e_act = -1000; e_mrs = -1000; n_ref = 0;
        cke_prev = 1; clk_run = 1; cke_low_rep = 0; pause_cke_rep = 0; t_cke_chg = -1.0e9;
        pre_all_done = 0; ref_deadline_rep = 0; first_cmd_seen = 0; pause_dqm_rep = 0;
        for (i = 0; i < 4; i = i + 1) begin
            t_act[i] = -1.0e9; t_pre[i] = -1.0e9; e_wr[i] = -1000; ras_max_rep[i] = 0;
        end
        for (i = 0; i < 4; i = i + 1) begin row_open[i] = 0; open_row[i] = 0; end
        for (i = 0; i < 8; i = i + 1) begin pipe_v[i] = 0; pipe_d[i] = 0; end
    end

    always @(posedge clk) begin
        clk_run = cke_prev;
        cke_prev = cke;
        check_edge;
        if (clk_run) begin

            // -- shift the output pipeline one edge ---------------
            for (i = 0; i < 7; i = i + 1) begin
                pipe_d[i] = pipe_d[i+1];
                pipe_v[i] = pipe_v[i+1];
            end
            pipe_v[7] = 1'b0;

            // オートプリチャージ付きの読み書きの途中か。後続の処理が rd_act と wr_act をクリアする前に保持する
            wr_ap_busy = wr_act && wr_ap;
            burst_busy = rd_act || wr_act;
            rd_ap_busy = rd_act && rd_ap;

            // 同じバンクの PRE で読み出しを止める。すでに出力が決まった値は残るので、PRE の CL - 1 個後のエッジまで値が出る
            if (rd_act && cmd == CMD_PRE && (addr[10] || ba == rd_bank)) rd_act = 1'b0;

            // -- continue an in-flight write burst ----------------
            // 別のバンクの ACT と PRE では、書き込みを続ける (バンクごとの動作。データシートの 11.5)
            if (wr_act && (cmd == CMD_NOP || cmd == CMD_ACT ||
                           (cmd == CMD_PRE && !addr[10] && ba != wr_bank))) begin
                col = burst_col(wr_col0, wr_beat, bl);
                fa = flat(wr_bank, wr_row, col);
                check_write_data(wr_bank);
                if (fa < MEM_WORDS) begin
                    w = mem[fa];
                    if (!dqm[0]) w[7:0]  = dq[7:0];
                    if (!dqm[1]) w[15:8] = dq[15:8];
                    mem[fa] = w;
                end
                wr_beat = wr_beat + 1;
                if (!full_page && wr_beat >= bl) begin
                    wr_act = 1'b0;
                    if (wr_ap) begin row_open[wr_bank] = 1'b0; auto_pre(wr_bank, T_WR_CK); end
                end
            end else if (wr_act) begin
                wr_act = 1'b0;          // 残りのコマンドは書き込みを打ち切る
            end

            // -- continue an in-flight read burst -----------------
            if (rd_act && (cmd == CMD_NOP || cmd == CMD_ACT || cmd == CMD_PRE ||
                           cmd == CMD_REFRESH)) begin
                col = burst_col(rd_col0, rd_beat, bl);
                rd_word(flat(rd_bank, rd_row, col), w);
                pipe_d[cl-1] = w;
                pipe_v[cl-1] = 1'b1;
                rd_beat = rd_beat + 1;
                if (!full_page && rd_beat >= bl) begin
                    rd_act = 1'b0;
                    if (rd_ap) begin row_open[rd_bank] = 1'b0; auto_pre(rd_bank, 1); end
                end
            end

            check_cmd;
            case (cmd)
                CMD_MRS: begin
                    for (i = 0; i < 4; i = i + 1)
                        if (row_open[i]) begin
                            $display("SDRAM ERROR @%0t: MRS with bank %0d open", $time, i);
                            errors = errors + 1;
                        end
                    full_page = (addr[2:0] == 3'd7) && !addr[3];
                    case (addr[2:0])
                        3'd0: bl = 1; 3'd1: bl = 2; 3'd2: bl = 4; 3'd3: bl = 8;
                        default: if (!full_page) begin
                            $display("SDRAM ERROR @%0t: unsupported BL code %0d", $time, addr[2:0]);
                            errors = errors + 1;
                        end
                    endcase
                    cl = addr[6:4];
                    if (cl != 2 && cl != 3) begin
                        $display("SDRAM ERROR @%0t: unsupported CAS latency %0d", $time, cl);
                        errors = errors + 1;
                    end
                    single_write = addr[9];
                    interleave = addr[3];
                    // 予約ビットは 0 にする (データシートの 10.4)
                    if (addr[8:7] != 2'b00 || addr[12:10] != 3'b000 || ba != 2'b00) begin
                        $display("SDRAM ERROR @%0t: MRS reserved bit is set", $time);
                        errors = errors + 1;
                    end
                    mode_set = 1'b1;
                end
                CMD_REFRESH: begin
                    for (i = 0; i < 4; i = i + 1)
                        if (row_open[i]) begin
                            $display("SDRAM ERROR @%0t: REFRESH with bank %0d open", $time, i);
                            errors = errors + 1;
                        end
                end
                CMD_PRE: begin
                    if (addr[10]) for (i = 0; i < 4; i = i + 1) row_open[i] = 1'b0;
                    else row_open[ba] = 1'b0;
                end
                CMD_ACT: begin
                    if (!mode_set) begin
                        $display("SDRAM ERROR @%0t: ACT before MRS", $time);
                        errors = errors + 1;
                    end
                    if (row_open[ba]) begin
                        $display("SDRAM ERROR @%0t: ACT bank %0d row %0d, row %0d already open",
                            $time, ba, addr, open_row[ba]);
                        errors = errors + 1;
                    end
                    row_open[ba] = 1'b1;
                    open_row[ba] = addr;
                end
                CMD_READ: begin
                    if (!row_open[ba]) begin
                        $display("SDRAM ERROR @%0t: READ bank %0d with no open row", $time, ba);
                        errors = errors + 1;
                    end
                    reads = reads + 1;
                    rd_act = 1'b1;
                    rd_bank = ba;
                    rd_row = open_row[ba];
                    rd_col0 = addr[8:0];
                    rd_ap = addr[10];
                    rd_beat = 0;
                    col = burst_col(rd_col0, 0, bl);
                    rd_word(flat(rd_bank, rd_row, col), w);
                    pipe_d[cl-1] = w;
                    pipe_v[cl-1] = 1'b1;
                    rd_beat = 1;
                    if (!full_page && rd_beat >= bl) begin
                        rd_act = 1'b0;
                        if (rd_ap) begin row_open[ba] = 1'b0; auto_pre(ba, 1); end
                    end
                end
                CMD_WRITE: begin
                    if (!row_open[ba]) begin
                        $display("SDRAM ERROR @%0t: WRITE bank %0d with no open row", $time, ba);
                        errors = errors + 1;
                    end
                    writes = writes + 1;
                    // a WRITE truncates a read burst
                    rd_act = 1'b0;
                    for (i = 0; i < 8; i = i + 1) pipe_v[i] = 1'b0;
                    fa = flat(ba, open_row[ba], addr[8:0]);
                    check_write_data(ba);
                    if (fa < MEM_WORDS) begin
                        w = mem[fa];
                        if (!dqm[0]) w[7:0]  = dq[7:0];
                        if (!dqm[1]) w[15:8] = dq[15:8];
                        mem[fa] = w;
                    end
                    wr_bank = ba;
                    wr_row = open_row[ba];
                    wr_col0 = addr[8:0];
                    wr_beat = 1;
                    wr_act = !single_write && (bl > 1 || full_page);
                    wr_ap = addr[10];
                    if (addr[10] && !wr_act) begin row_open[ba] = 1'b0; auto_pre(ba, T_WR_CK); end
                end
                CMD_BST: begin
                    rd_act = 1'b0;
                    wr_act = 1'b0;
                end
                default: ;
            endcase

            // -- read DQM, 2-edge latency: masks the beat sampled
            //    two edges after it was presented
            rdqm_1 = rdqm_0;
            rdqm_0 = dqm;
        end

        // -- drive DQ for the beat sampled at the NEXT edge -------
        // clk_run が 0 のエッジでは DQ をそのまま保持する (データシートの 10.3)
        // tOH の後は、次の値が出る tAC か、ハイインピーダンスになる tHZ の最大値まで値が定まらない。ハイインピーダンスのバイトはそのまま
        if (!clk_run) begin
        end else if (pipe_v[0] || dq_oe) begin
            if (pipe_v[0]) t_dly = (cl == 3) ? TAC_CL3 : TAC_CL2;
            else t_dly = (cl == 3) ? THZ_CL3 : THZ_CL2;
            #(TOH);
            if (dq_oe) begin
                if (dq_out[7:0] !== 8'hzz) dq_out[7:0] = 8'hxx;
                if (dq_out[15:8] !== 8'hzz) dq_out[15:8] = 8'hxx;
            end
            #(t_dly - TOH);
            if (pipe_v[0]) begin
                // DQM はバイトごとに効く (データシートの 5 章)
                dq_out[7:0]  = rdqm_1[0] ? 8'hzz : pipe_d[0][7:0];
                dq_out[15:8] = rdqm_1[1] ? 8'hzz : pipe_d[0][15:8];
                dq_oe = 1'b1;
            end else
                dq_oe = 1'b0;
        end
    end

endmodule
