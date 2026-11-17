// =============================================================
// File:        rtl/ae350_fabric.v
// Module:      ae350_fabric
// Role:        AE350 の Hazard3 版の内部バス。シミュレーションと、FPGA のファブリック上の Hazard3 版で使う。
//              本物の AE350 と同じく、AHB_CLK で動く中央バスがすべての転送を受け、転送先ごとのクロックへ
//              ブリッジでつなぐ。
//
//   CPU (CORE_CLK) ──クロック乗せ換え──▶ 中央バス (AHB_CLK) ──▶ ROM_H*、PLIC、PLMT、EXTS_H*、ILM と DLM
//   EXTM_H* (AHB_CLK) ─────────────────▶ (CPU と同じアドレス空間。中央バスが CPU と交互に 1 つずつ処理する)
//                                                  ──クロック乗せ換え──▶ DDR_H* (DDR_CLK)
//                                                  ──クロック乗せ換え──▶ APB_P* (APB_CLK)
//
//   アドレス                             転送先
//   0x8000_0000〜0x8FFF_FFFF (読み出し)  ROM_H* の転送 (32 ビット)
//   0xE400_0000〜0xE5FF_FFFF             PLIC のレジスタ (ae350_plic)
//   0xE600_0000〜0xE60F_FFFF             PLMT のレジスタ (ae350_plmt)
//   0x0000_0000〜0x7FFF_FFFF             DDR_H* の転送 (64 ビット)
//   0xF800_0000〜0xFBFF_FFFF             APB_P* の転送 (SETUP → ACCESS。PSLVERR はエラー応答に変換する)
//   0xE800_0000〜0xEFFF_FFFF             EXTS_H* の転送 (32 ビット、AHB_CLK。HADDR はフルアドレス)
//   0xA000_0000〜0xA000_FFFF             ILM (64 KB、64 ビット幅の内蔵メモリ)。中央バスからは 2 サイクルで読み書きする。
//                                        CPU は中央バスを通らず、ポート A からウェイトなしで読み書きする
//   0xA020_0000〜0xA020_FFFF             DLM (ILM と同じ構成)
//   上記以外と、ROM の範囲への書き込み   中央バスがエラー応答を返す
//
// クロックの関係: Gowin の AE350 のリファレンスデザインは、CORE 800 MHz、AHB 100 MHz、APB 100 MHz、DDR 50 MHz を
// 1 つの PLL から生成し、SDC では互いに非同期として扱う。そのため、どのクロック比でも動くように、非同期の
// ハンドシェイクでつなぐ。
//
// クロック乗せ換え (CDC): 要求側は転送の内容をレジスタに保持してから、要求信号 (req_*_t) を反転させる。
// 応答側はそれを 2 段の FF で同期化して受け、処理が終わると応答をレジスタに置いて完了信号 (ack_*_t) を反転させる。
// 要求から完了までの間、保持した内容と応答は変化しないので、複数ビットの信号をそのまま相手のクロックで読んでよい。
//
// 中央バスの転送は 64 ビットで表す (EXTM_H* が 64 ビットのため)。
//   addr、write、size (HSIZE、0〜3)、prot、wdata (64 ビット)、strb (8 バイトのうち書き込むバイトレーン)
//   応答は rdata (64 ビット) と err。32 ビットの転送先には、64 ビットのうち addr[2] で選ばれる側の 32 ビットを使う。
//   32 ビットの転送先への 64 ビットの転送 (size 3) はエラー応答にする。
//
// EXTM_H* (FPGA 側のマスタから見たスレーブ。AHB_CLK、64 ビット):
//   - HSEL が 1、HTRANS が NONSEQ か SEQ、HREADY が 1 のサイクルにアドレスフェーズを受け付ける
//   - データフェーズの最初のサイクルに HWDATA を保持して中央バスに要求し、完了するまで HREADYOUT を 0 にする
//   - 64 ビットの中のバイトレーンは、AHB の規定どおりアドレスの下位 3 ビットと HSIZE で決まる (32 ビットの転送で
//     HADDR[2] が 1 なら上側の 32 ビット)。32 ビットの転送先への 64 ビットの転送はエラー応答にする
//   - HBURST は見ない (バースト転送も 1 つずつ処理する)
//   - EXTM_H* が AHB_CLK で動き、DDR を含む AE350 のアドレス空間にアクセスできることは、Gowin の AE350 の資料で
//     確認した
//
// CPU 側の AHB (Hazard3 から見たスレーブ):
//   - HREADY が 1 のサイクル (転送を待っていないときか、前の転送が終わるサイクル) にアドレスフェーズを受け付ける
//   - データフェーズの最初のサイクルに HWDATA を保持して中央バスに要求し、完了するまで HREADY を 0 にする
//   - 完了したら、正常時は HREADY を 1 にして HRDATA を返す。エラー時は HRESP を 2 サイクル 1 にする
//     (1 サイクル目は HREADY が 0)
// =============================================================

`default_nettype none

module ae350_fabric (
    // CPU 側 (CORE_CLK)
    input  wire        core_clk,
    input  wire        core_rst_n,
    input  wire [31:0] c_haddr,
    input  wire        c_hwrite,
    input  wire [1:0]  c_htrans,
    input  wire [2:0]  c_hsize,
    input  wire [3:0]  c_hprot,
    input  wire [31:0] c_hwdata,
    output reg         c_hready,
    output reg         c_hresp,
    output reg  [31:0] c_hrdata,

    // 中央バス (AHB_CLK): ROM_H*、PLIC と PLMT のレジスタ
    input  wire        ahb_clk,
    input  wire        ahb_rst_n,
    output reg  [31:0] rom_haddr,
    output reg  [1:0]  rom_htrans,
    input  wire [31:0] rom_hrdata,
    input  wire        rom_hready,
    input  wire        rom_hresp,
    output reg         plic_wen,
    output reg         plic_ren,
    output reg         plmt_wen,
    output reg  [21:0] reg_addr,
    output reg  [31:0] reg_wdata,
    output reg  [3:0]  reg_wstrb,
    input  wire [31:0] plic_rdata,
    input  wire [31:0] plmt_rdata,
    // EXTS_H* (中央バスと同じ AHB_CLK、32 ビット)
    output reg  [31:0] exts_haddr,
    output reg  [1:0]  exts_htrans,
    output reg         exts_hsel,
    output reg         exts_hwrite,
    output reg  [2:0]  exts_hsize,
    output reg  [3:0]  exts_hprot,
    output reg  [31:0] exts_hwdata,
    input  wire [31:0] exts_hrdata,
    input  wire        exts_hready,     // EXTS_HREADYIN (スレーブの HREADYOUT)
    input  wire        exts_hresp,
    // EXTM_H* (AHB_CLK、64 ビット。AE350 がスレーブ)
    input  wire        extm_hsel,
    input  wire [31:0] extm_haddr,
    input  wire [1:0]  extm_htrans,
    input  wire        extm_hwrite,
    input  wire [2:0]  extm_hsize,
    input  wire [3:0]  extm_hprot,
    input  wire [63:0] extm_hwdata,
    input  wire        extm_hready,
    output reg  [63:0] extm_hrdata,
    output reg         extm_hreadyout,
    output reg         extm_hresp,

    // DDR_CLK 側: DDR_H*
    input  wire        ddr_clk,
    input  wire        ddr_rst_n,
    output reg  [31:0] ddr_haddr,
    output reg  [1:0]  ddr_htrans,
    output reg         ddr_hwrite,
    output reg  [2:0]  ddr_hsize,
    output reg  [3:0]  ddr_hprot,
    output reg  [63:0] ddr_hwdata,
    input  wire [63:0] ddr_hrdata,
    input  wire        ddr_hready,
    input  wire        ddr_hresp,

    // APB_CLK 側: APB_P*
    input  wire        apb_clk,
    input  wire        apb_rst_n,
    output reg  [31:0] apb_paddr,
    output reg         apb_psel,
    output reg         apb_penable,
    output reg         apb_pwrite,
    output reg  [31:0] apb_pwdata,
    output reg  [3:0]  apb_pstrb,
    output reg  [2:0]  apb_pprot,
    input  wire [31:0] apb_prdata,
    input  wire        apb_pready,
    input  wire        apb_pslverr
);

    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;

    // 8 バイトのうち書き込むバイトレーン (読み出しでは 0)
    function [7:0] lanes(input [2:0] a, input [2:0] size, input write);
        begin
            case (size)
                3'd0:    lanes = 8'b0000_0001 << a;
                3'd1:    lanes = 8'b0000_0011 << {a[2:1], 1'b0};
                3'd2:    lanes = 8'b0000_1111 << {a[2], 2'b00};
                default: lanes = 8'b1111_1111;
            endcase
            if (!write) lanes = 8'b0000_0000;
        end
    endfunction

    // =========================================================
    // CPU 側 (CORE_CLK): Hazard3 の AHB を受けて、中央バスに要求する
    // =========================================================
    localparam [2:0] C_IDLE = 3'd0;   // データフェーズなし
    localparam [2:0] C_DPH  = 3'd1;   // データフェーズの最初のサイクル (HWDATA を保持して要求する)
    localparam [2:0] C_WAIT = 3'd2;   // 完了を待つ
    localparam [2:0] C_DONE = 3'd3;   // 正常に完了した (HREADY = 1)
    localparam [2:0] C_ERR1 = 3'd4;   // エラー応答の 1 サイクル目
    localparam [2:0] C_ERR2 = 3'd5;   // エラー応答の 2 サイクル目
    localparam [2:0] C_TCM  = 3'd6;   // ILM と DLM のデータフェーズ (ポート A からウェイトなしで読み書きする)
    localparam [2:0] C_TCM_RAW = 3'd7;   // ILM と DLM に書き込んだ直後の読み出しを、1 サイクル待たせる

    reg  [2:0]  c_state;

    // CPU の転送の内容 (要求してから完了するまで変えない)
    reg  [31:0] cq_addr;
    reg         cq_write;
    reg  [2:0]  cq_size;
    reg  [3:0]  cq_prot;
    reg  [31:0] cq_wdata;

    reg         creq_t;         // CPU → 中央バス: 要求 (トグル)
    reg         cack_t;         // 中央バス → CPU: 完了 (トグル。中央バス側のレジスタ)
    reg  [1:0]  cack_s;         // CPU 側で 2 段同期化したもの
    reg  [63:0] cresp_data;     // 中央バスの応答 (完了してから次に要求するまで変えない)
    reg         cresp_err;

    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) cack_s <= 2'b00;
        else             cack_s <= {cack_s[0], cack_t};
    end

    wire c_done = (cack_s[1] == creq_t);
    reg  [31:0] c_rdata_q;

    // ILM と DLM のポート A (CPU 側、core_clk)。読み出しは、アドレスフェーズのサイクルにアドレスを渡し、データフェーズで
    // 値を返す。書き込みはデータフェーズで行う。書き込んだ直後の読み出しは、同じアドレスの書き込み前の値を読まないように
    // 1 サイクル待たせる (C_TCM_RAW)。メモリ本体は、後の中央バス側にある g_tcm (ポート B と共有するデュアルポートメモリ)
    wire        c_tcm_hit  = (c_haddr[31:16] == 16'hA000) || (c_haddr[31:16] == 16'hA020);
    wire [12:0] c_tcm_ridx = (c_state == C_TCM_RAW) ? cq_addr[15:3] : c_haddr[15:3];
    wire        c_tcm_we   = (c_state == C_TCM) && cq_write;
    wire [7:0]  c_tcm_strb = lanes(cq_addr[2:0], cq_size, 1'b1);
    wire [63:0] c_ilm_q;
    wire [63:0] c_dlm_q;
    wire [63:0] c_tcm_q     = cq_addr[21] ? c_dlm_q : c_ilm_q;   // 0xA020_0000〜 が DLM
    wire [31:0] c_tcm_rdata = cq_addr[2] ? c_tcm_q[63:32] : c_tcm_q[31:0];

    always @(*) begin
        c_hready = 1'b1;
        c_hresp  = 1'b0;
        c_hrdata = 32'd0;
        case (c_state)
            C_DPH, C_WAIT: c_hready = 1'b0;
            C_DONE:        c_hrdata = c_rdata_q;
            C_ERR1: begin
                c_hready = 1'b0;
                c_hresp  = 1'b1;
            end
            C_ERR2:        c_hresp  = 1'b1;
            C_TCM:         c_hrdata = c_tcm_rdata;
            C_TCM_RAW:     c_hready = 1'b0;
            default: ;
        endcase
    end

    wire c_accept = c_hready && c_htrans[1];

    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            c_state   <= C_IDLE;
            cq_addr   <= 32'd0;
            cq_write  <= 1'b0;
            cq_size   <= 3'd0;
            cq_prot   <= 4'd0;
            cq_wdata  <= 32'd0;
            creq_t    <= 1'b0;
            c_rdata_q <= 32'd0;
        end else begin
            case (c_state)
                C_DPH: begin
                    cq_wdata <= c_hwdata;
                    creq_t   <= ~creq_t;
                    c_state  <= C_WAIT;
                end
                C_WAIT: begin
                    if (c_done) begin
                        c_rdata_q <= cq_addr[2] ? cresp_data[63:32] : cresp_data[31:0];
                        c_state   <= cresp_err ? C_ERR1 : C_DONE;
                    end
                end
                C_ERR1:  c_state <= C_ERR2;
                C_TCM_RAW: c_state <= C_TCM;
                default: c_state <= C_IDLE;   // C_IDLE、C_DONE、C_ERR2 (次のアドレスを受け付けたときは、下で上書きする)
            endcase

            if (c_accept) begin
                if (c_tcm_hit)   // ILM と DLM はポート A で直接読み書きする (中央バスには要求しない)
                    c_state <= (c_state == C_TCM && cq_write && !c_hwrite) ? C_TCM_RAW : C_TCM;
                else
                    c_state <= C_DPH;
                cq_addr  <= c_haddr;
                cq_write <= c_hwrite;
                cq_size  <= c_hsize;
                cq_prot  <= c_hprot;
            end
        end
    end

    // =========================================================
    // 中央バス (AHB_CLK)
    // =========================================================
    // 要求元 1: CPU (クロック乗せ換えして受ける)
    reg  [1:0] creq_s;
    always @(posedge ahb_clk or negedge ahb_rst_n) begin
        if (!ahb_rst_n) creq_s <= 2'b00;
        else            creq_s <= {creq_s[0], creq_t};
    end
    wire cpu_pending = (creq_s[1] != cack_t);

    // 要求元 2: EXTM_H* (AHB_CLK のスレーブとして受ける)
    localparam [2:0] E_IDLE = 3'd0;
    localparam [2:0] E_DPH  = 3'd1;   // データフェーズの最初のサイクル (HWDATA を保持して要求する)
    localparam [2:0] E_WAIT = 3'd2;
    localparam [2:0] E_DONE = 3'd3;
    localparam [2:0] E_ERR1 = 3'd4;
    localparam [2:0] E_ERR2 = 3'd5;

    reg  [2:0]  e_state;
    reg  [31:0] eq_addr;
    reg         eq_write;
    reg  [2:0]  eq_size;
    reg  [3:0]  eq_prot;
    reg  [63:0] eq_wdata;
    reg         extm_pending;     // 中央バスに要求している
    reg         extm_done;        // 中央バスが処理を終えた (1 サイクル)
    reg  [63:0] eresp_data;
    reg         eresp_err;

    always @(*) begin
        extm_hreadyout = 1'b1;
        extm_hresp     = 1'b0;
        extm_hrdata    = 64'd0;
        case (e_state)
            E_DPH, E_WAIT: extm_hreadyout = 1'b0;
            E_DONE:        extm_hrdata    = eresp_data;
            E_ERR1: begin
                extm_hreadyout = 1'b0;
                extm_hresp     = 1'b1;
            end
            E_ERR2:        extm_hresp     = 1'b1;
            default: ;
        endcase
    end

    wire e_accept = extm_hsel && extm_htrans[1] && extm_hready;

    always @(posedge ahb_clk or negedge ahb_rst_n) begin
        if (!ahb_rst_n) begin
            e_state      <= E_IDLE;
            eq_addr      <= 32'd0;
            eq_write     <= 1'b0;
            eq_size      <= 3'd0;
            eq_prot      <= 4'd0;
            eq_wdata     <= 64'd0;
            extm_pending <= 1'b0;
        end else begin
            case (e_state)
                E_DPH: begin
                    eq_wdata     <= extm_hwdata;
                    extm_pending <= 1'b1;
                    e_state      <= E_WAIT;
                end
                E_WAIT: begin
                    if (extm_done) begin
                        extm_pending <= 1'b0;
                        e_state      <= eresp_err ? E_ERR1 : E_DONE;
                    end
                end
                E_ERR1:  e_state <= E_ERR2;
                default: e_state <= E_IDLE;   // E_IDLE、E_DONE、E_ERR2 (次のアドレスを受け付けたときは、下で上書きする)
            endcase

            if (e_accept) begin
                e_state  <= E_DPH;
                eq_addr  <= extm_haddr;
                eq_write <= extm_hwrite;
                eq_size  <= extm_hsize;
                eq_prot  <= extm_hprot;
            end
        end
    end

    // どちらの要求元を処理するか: 両方が要求しているときは、前回処理しなかった方を選ぶ (交互に処理する)
    reg  last_extm;     // 前回処理したのが EXTM_H*
    wire pick_extm = extm_pending && (!cpu_pending || !last_extm);

    // 選んだ要求元の転送 (要求している間、cq_* と eq_* は変わらない)
    wire [31:0] r_addr  = pick_extm ? eq_addr  : cq_addr;
    wire        r_write = pick_extm ? eq_write : cq_write;
    wire [2:0]  r_size  = pick_extm ? eq_size  : cq_size;
    wire [3:0]  r_prot  = pick_extm ? eq_prot  : cq_prot;
    wire [63:0] r_wdata = pick_extm ? eq_wdata : {cq_wdata, cq_wdata};   // CPU は 32 ビットなので、上下に同じ値を置く
    wire [7:0]  r_lanes = lanes(r_addr[2:0], r_size, r_write);
    wire [3:0]  r_tgt;
    wire        r_any   = cpu_pending || extm_pending;

    // 転送先
    localparam [3:0] T_ERR  = 4'd0;
    localparam [3:0] T_ROM  = 4'd1;
    localparam [3:0] T_PLIC = 4'd2;
    localparam [3:0] T_PLMT = 4'd3;
    localparam [3:0] T_DDR  = 4'd4;
    localparam [3:0] T_APB  = 4'd5;
    localparam [3:0] T_EXTS = 4'd6;
    localparam [3:0] T_ILM  = 4'd7;
    localparam [3:0] T_DLM  = 4'd8;

    // 転送先は上位 16 ビットだけで決める (下位は見ない)
    function [3:0] decode(input [31:16] a, input write, input [2:0] size);
        begin
            if (a[31:28] == 4'h8)             decode = (write || size == 3'd3) ? T_ERR : T_ROM;
            else if (!a[31])                  decode = T_DDR;
            else if (a[31:26] == 6'b1111_10)  decode = (size == 3'd3) ? T_ERR : T_APB;    // 0xF800_0000〜
            else if (a[31:25] == 7'b1110_010) decode = (size == 3'd3) ? T_ERR : T_PLIC;   // 0xE400_0000〜
            else if (a[31:20] == 12'hE60)     decode = (size == 3'd3) ? T_ERR : T_PLMT;   // 0xE600_0000〜
            else if (a[31:27] == 5'b1110_1)   decode = (size == 3'd3) ? T_ERR : T_EXTS;   // 0xE800_0000〜
            else if (a[31:16] == 16'hA000)    decode = T_ILM;                             // 0xA000_0000〜
            else if (a[31:16] == 16'hA020)    decode = T_DLM;                             // 0xA020_0000〜
            else                              decode = T_ERR;
        end
    endfunction

    assign r_tgt = decode(r_addr[31:16], r_write, r_size);

    // 処理中の転送 (中央バス側のレジスタ。転送先のクロック側は、要求から完了までの間これを読む)
    reg  [31:0] bq_addr;
    reg         bq_write;
    reg  [2:0]  bq_size;
    reg  [3:0]  bq_prot;
    reg  [63:0] bq_wdata;
    reg  [7:0]  bq_strb;

    localparam [3:0] B_IDLE = 4'd0;
    localparam [3:0] B_ROM_AP = 4'd1;   // ROM_H* のアドレスフェーズ
    localparam [3:0] B_ROM_DP = 4'd2;   // ROM_H* のデータフェーズ
    localparam [3:0] B_REG  = 4'd3;     // PLIC と PLMT の読み書き (1 サイクル)
    localparam [3:0] B_FAR  = 4'd4;     // DDR 側か APB 側に要求して、完了を待つ
    localparam [3:0] B_EXTS_AP = 4'd5;  // EXTS_H* のアドレスフェーズ
    localparam [3:0] B_EXTS_DP = 4'd6;  // EXTS_H* のデータフェーズ
    localparam [3:0] B_TCM  = 4'd7;     // ILM と DLM に書き込み、メモリを読んでレジスタで受ける
    localparam [3:0] B_TCM_RD = 4'd8;   // ILM と DLM から読んだ値を返す

    reg  [3:0]  b_state;
    reg  [3:0]  b_tgt;
    reg         b_extm;     // 処理中の転送の要求元が EXTM_H*

    // ILM と DLM (それぞれ 64 KB、64 ビット幅)。内容は初期化しない (本物の SRAM と同じく、リセット後の値は不定)。
    // デュアルポートメモリにする。ポート A は CPU が core_clk で直接読み書きし (上の c_tcm_*、ウェイトなし)、ポート B は
    // 中央バスが ahb_clk で読み書きする (EXTM_H* からの転送。B_TCM で読み書きしてレジスタで受け、B_TCM_RD で返す)。
    // 2 つのクロックの間の受け渡しは、メモリ自身が受け持つ。両方のポートから同じアドレスに同時に書き込んだときの値は
    // 不定とする (本物の SRAM と同じ扱い)。バイトごとに 8 個のメモリに分け、書き込みのバイトレーンを、そのまま各メモリの
    // 書き込み許可にする。
    //
    // 各ポートが 1 サイクルに使えるアドレスは 1 つ (書き込むサイクルは書き込むアドレスを読み、それ以外のサイクルは
    // 読み出すアドレスを読む)。FPGA のブロック RAM (Gowin の DPB) と同じ動作にして、シミュレーションと FPGA の動作を
    // 揃える。書き込んだ直後の読み出しは、CPU 側の C_TCM_RAW で読み直す。
    //
    //   AE350_GOWIN_BSRAM あり (board/tang_console/build.sh の Hazard3 版)  Gowin の DPB を置く (Gowin の合成ツールは、
    //                                    2 つのクロックで書き込むメモリを always の記述から推論できないため)
    //   なし (シミュレーション、lint)    always で記述したメモリ
    localparam integer TCM_WORDS = 8192;
    wire [12:0] tcm_idx    = bq_addr[15:3];
    wire        tcm_cycle  = (b_state == B_TCM);
    wire [12:0] c_tcm_aidx = c_tcm_we ? cq_addr[15:3] : c_tcm_ridx;   // ポート A がこのサイクルに使うアドレス
    wire [63:0] ilm_q;
    wire [63:0] dlm_q;
    genvar      gl;
    generate
        for (gl = 0; gl < 8; gl = gl + 1) begin : g_tcm
            wire       ilm_wea = c_tcm_we && !cq_addr[21] && c_tcm_strb[gl];
            wire       dlm_wea = c_tcm_we &&  cq_addr[21] && c_tcm_strb[gl];
            wire [7:0] dia     = c_hwdata[(gl % 4)*8 +: 8];
            wire       ilm_web = tcm_cycle && b_tgt == T_ILM && bq_strb[gl];
            wire       dlm_web = tcm_cycle && b_tgt == T_DLM && bq_strb[gl];
            wire [7:0] dib     = bq_wdata[gl*8 +: 8];
            wire [7:0] ilm_qa, dlm_qa, ilm_qb, dlm_qb;
`ifdef AE350_GOWIN_BSRAM
            // 1 個 (8 KB) を、DPB (8 ビット幅で 2,048 バイト) 4 個で構成する。どの DPB を使うかはアドレスの上位 2 ビット
            // (BLKSEL) で選び、読み出した値は、読み出したサイクルに保持した上位 2 ビットで選ぶ (選ばれていない DPB は出力を保持する)
            reg  [1:0] bank_a, bank_b;
            always @(posedge core_clk) bank_a <= c_tcm_aidx[12:11];
            always @(posedge ahb_clk)  bank_b <= tcm_idx[12:11];
            wire [15:0] ilm_doa [0:3];
            wire [15:0] dlm_doa [0:3];
            wire [15:0] ilm_dob [0:3];
            wire [15:0] dlm_dob [0:3];
            genvar gk;
            for (gk = 0; gk < 4; gk = gk + 1) begin : g_bank
                // BLK_SEL_* は 3 ビット (BLKSELA、BLKSELB と同じ幅)。genvar をそのまま渡すと、合成ツールがビット幅の警告 (EX0346) を出す
                localparam [2:0] BLK_SEL = gk;
                DPB #(.READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
                      .BIT_WIDTH_0 (8), .BIT_WIDTH_1 (8), .BLK_SEL_0 (BLK_SEL), .BLK_SEL_1 (BLK_SEL), .RESET_MODE ("SYNC")) u_ilm (
                    .DOA (ilm_doa[gk]), .DOB (ilm_dob[gk]), .DIA ({8'd0, dia}), .DIB ({8'd0, dib}),
                    .BLKSELA ({1'b0, c_tcm_aidx[12:11]}), .BLKSELB ({1'b0, tcm_idx[12:11]}),
                    .ADA ({c_tcm_aidx[10:0], 3'b000}), .ADB ({tcm_idx[10:0], 3'b000}),
                    .WREA (ilm_wea), .WREB (ilm_web), .CLKA (core_clk), .CLKB (ahb_clk),
                    .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1), .RESETA (1'b0), .RESETB (1'b0));
                DPB #(.READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
                      .BIT_WIDTH_0 (8), .BIT_WIDTH_1 (8), .BLK_SEL_0 (BLK_SEL), .BLK_SEL_1 (BLK_SEL), .RESET_MODE ("SYNC")) u_dlm (
                    .DOA (dlm_doa[gk]), .DOB (dlm_dob[gk]), .DIA ({8'd0, dia}), .DIB ({8'd0, dib}),
                    .BLKSELA ({1'b0, c_tcm_aidx[12:11]}), .BLKSELB ({1'b0, tcm_idx[12:11]}),
                    .ADA ({c_tcm_aidx[10:0], 3'b000}), .ADB ({tcm_idx[10:0], 3'b000}),
                    .WREA (dlm_wea), .WREB (dlm_web), .CLKA (core_clk), .CLKB (ahb_clk),
                    .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1), .RESETA (1'b0), .RESETB (1'b0));
            end
            assign ilm_qa = ilm_doa[bank_a][7:0];
            assign dlm_qa = dlm_doa[bank_a][7:0];
            assign ilm_qb = ilm_dob[bank_b][7:0];
            assign dlm_qb = dlm_dob[bank_b][7:0];
`else
            // メモリは、リセットを持たない always で読み書きする
            /* verilator lint_off MULTIDRIVEN */
            reg [7:0] ilm_b [0:TCM_WORDS-1];
            reg [7:0] dlm_b [0:TCM_WORDS-1];
            /* verilator lint_on MULTIDRIVEN */
            reg [7:0] ilm_qa_r, dlm_qa_r, ilm_qb_r, dlm_qb_r;
            // ポート A (CPU)
            always @(posedge core_clk) begin
                if (ilm_wea) ilm_b[c_tcm_aidx] <= dia;
                if (dlm_wea) dlm_b[c_tcm_aidx] <= dia;
                ilm_qa_r <= ilm_b[c_tcm_aidx];
                dlm_qa_r <= dlm_b[c_tcm_aidx];
            end
            // ポート B (中央バス)
            always @(posedge ahb_clk) begin
                if (ilm_web) ilm_b[tcm_idx] <= dib;
                if (dlm_web) dlm_b[tcm_idx] <= dib;
                ilm_qb_r <= ilm_b[tcm_idx];
                dlm_qb_r <= dlm_b[tcm_idx];
            end
            assign ilm_qa = ilm_qa_r;
            assign dlm_qa = dlm_qa_r;
            assign ilm_qb = ilm_qb_r;
            assign dlm_qb = dlm_qb_r;
`endif
            assign c_ilm_q[gl*8 +: 8] = ilm_qa;
            assign c_dlm_q[gl*8 +: 8] = dlm_qa;
            assign ilm_q[gl*8 +: 8]   = ilm_qb;
            assign dlm_q[gl*8 +: 8]   = dlm_qb;
        end
    endgenerate
    wire [63:0] tcm_rdata = (b_tgt == T_ILM) ? ilm_q : dlm_q;

    // DDR 側と APB 側への要求 (トグル)
    reg         dreq_t, preq_t;
    reg         dack_t, pack_t;     // 転送先のクロック側のレジスタ
    reg  [1:0]  dack_s, pack_s;     // 中央バス側で 2 段同期化したもの
    reg  [63:0] dresp_data;
    reg         dresp_err;
    reg  [31:0] presp_data;
    reg         presp_err;

    wire far_done = (b_tgt == T_DDR) ? (dack_s[1] == dreq_t) : (pack_s[1] == preq_t);

    // 転送が完了したサイクルに、要求元へ応答を返す。受け付けたサイクルにそのまま返す場合 (B_IDLE でのエラー応答) は、
    // b_extm にまだ前の転送の要求元が入っているので、いま受け付けた要求元 (pick_extm) で返し先を決める
    task finish(input [63:0] data, input err);
        begin
            if ((b_state == B_IDLE) ? pick_extm : b_extm) begin
                eresp_data <= data;
                eresp_err  <= err;
                extm_done  <= 1'b1;
            end else begin
                cresp_data <= data;
                cresp_err  <= err;
                cack_t     <= ~cack_t;
            end
            b_state <= B_IDLE;
        end
    endtask

    always @(posedge ahb_clk or negedge ahb_rst_n) begin
        if (!ahb_rst_n) begin
            b_state    <= B_IDLE;
            b_tgt      <= T_ERR;
            b_extm     <= 1'b0;
            last_extm  <= 1'b0;
            extm_done  <= 1'b0;
            eresp_data <= 64'd0;
            eresp_err  <= 1'b0;
            bq_addr    <= 32'd0;
            bq_write   <= 1'b0;
            bq_size    <= 3'd0;
            bq_prot    <= 4'd0;
            bq_wdata   <= 64'd0;
            bq_strb    <= 8'd0;
            cack_t     <= 1'b0;
            cresp_data <= 64'd0;
            cresp_err  <= 1'b0;
            dreq_t     <= 1'b0;
            preq_t     <= 1'b0;
            dack_s     <= 2'b00;
            pack_s     <= 2'b00;
            rom_haddr  <= 32'd0;
            rom_htrans <= HTRANS_IDLE;
            exts_haddr  <= 32'd0;
            exts_htrans <= HTRANS_IDLE;
            exts_hsel   <= 1'b0;
            exts_hwrite <= 1'b0;
            exts_hsize  <= 3'd0;
            exts_hprot  <= 4'd0;
            exts_hwdata <= 32'd0;
            plic_wen   <= 1'b0;
            plic_ren   <= 1'b0;
            plmt_wen   <= 1'b0;
            reg_addr   <= 22'd0;
            reg_wdata  <= 32'd0;
            reg_wstrb  <= 4'd0;
        end else begin
            dack_s <= {dack_s[0], dack_t};
            pack_s <= {pack_s[0], pack_t};
            extm_done <= 1'b0;

            case (b_state)
                B_IDLE: begin
                    // EXTM_H* は、完了した次のサイクル (extm_done で E_WAIT を抜けるサイクル) にはまだ要求しているように
                    // 見えるので、そのサイクルは受け付けない
                    if (r_any && !(pick_extm && extm_done)) begin
                        bq_addr   <= r_addr;
                        bq_write  <= r_write;
                        bq_size   <= r_size;
                        bq_prot   <= r_prot;
                        bq_wdata  <= r_wdata;
                        bq_strb   <= r_lanes;
                        b_tgt     <= r_tgt;
                        b_extm    <= pick_extm;
                        last_extm <= pick_extm;
                        case (r_tgt)
                            T_ROM: begin
                                rom_haddr  <= r_addr;
                                rom_htrans <= HTRANS_NONSEQ;
                                b_state    <= B_ROM_AP;
                            end
                            T_PLIC, T_PLMT: begin
                                reg_addr  <= r_addr[21:0];
                                reg_wdata <= r_addr[2] ? r_wdata[63:32] : r_wdata[31:0];
                                reg_wstrb <= r_addr[2] ? r_lanes[7:4] : r_lanes[3:0];
                                plic_wen  <= (r_tgt == T_PLIC) &&  r_write;
                                plic_ren  <= (r_tgt == T_PLIC) && !r_write;
                                plmt_wen  <= (r_tgt == T_PLMT) &&  r_write;
                                b_state   <= B_REG;
                            end
                            T_DDR: begin
                                dreq_t  <= ~dreq_t;
                                b_state <= B_FAR;
                            end
                            T_EXTS: begin
                                exts_haddr  <= r_addr;
                                exts_hwrite <= r_write;
                                exts_hsize  <= r_size;
                                exts_hprot  <= r_prot;
                                exts_htrans <= HTRANS_NONSEQ;
                                exts_hsel   <= 1'b1;
                                b_state     <= B_EXTS_AP;
                            end
                            T_ILM, T_DLM: b_state <= B_TCM;
                            T_APB: begin
                                preq_t  <= ~preq_t;
                                b_state <= B_FAR;
                            end
                            default: finish(64'd0, 1'b1);
                        endcase
                    end
                end
                B_ROM_AP: begin
                    if (rom_hready) begin
                        rom_htrans <= HTRANS_IDLE;
                        b_state    <= B_ROM_DP;
                    end
                end
                B_ROM_DP: begin
                    if (rom_hready) begin
                        finish({rom_hrdata, rom_hrdata}, rom_hresp);
                    end
                end
                B_REG: begin   // このサイクルで PLIC と PLMT が読み書きする
                    plic_wen <= 1'b0;
                    plic_ren <= 1'b0;
                    plmt_wen <= 1'b0;
                    finish((b_tgt == T_PLIC) ? {plic_rdata, plic_rdata} : {plmt_rdata, plmt_rdata}, 1'b0);
                end
                B_EXTS_AP: begin
                    if (exts_hready) begin
                        exts_htrans <= HTRANS_IDLE;
                        exts_hsel   <= 1'b0;
                        exts_hwdata <= bq_addr[2] ? bq_wdata[63:32] : bq_wdata[31:0];
                        b_state     <= B_EXTS_DP;
                    end
                end
                B_EXTS_DP: begin
                    if (exts_hready) finish({exts_hrdata, exts_hrdata}, exts_hresp);
                end
                B_TCM: begin   // このサイクルでメモリに書き込み、読み出してレジスタで受ける (上の g_tcm)
                    b_state <= B_TCM_RD;
                end
                B_TCM_RD: begin
                    finish(tcm_rdata, 1'b0);
                end
                default: begin   // B_FAR
                    if (far_done) begin
                        finish((b_tgt == T_DDR) ? dresp_data : {presp_data, presp_data},
                               (b_tgt == T_DDR) ? dresp_err  : presp_err);
                    end
                end
            endcase
        end
    end

    // =========================================================
    // DDR_CLK 側: DDR_H*
    // =========================================================
    localparam [1:0] D_IDLE = 2'd0;
    localparam [1:0] D_AP   = 2'd1;
    localparam [1:0] D_DP   = 2'd2;

    reg [1:0] d_state;
    reg [1:0] dreq_s;
    wire      d_pending = (dreq_s[1] != dack_t);

    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            dreq_s     <= 2'b00;
            d_state    <= D_IDLE;
            dack_t     <= 1'b0;
            dresp_data <= 64'd0;
            dresp_err  <= 1'b0;
            ddr_haddr  <= 32'd0;
            ddr_htrans <= HTRANS_IDLE;
            ddr_hwrite <= 1'b0;
            ddr_hsize  <= 3'd0;
            ddr_hprot  <= 4'd0;
            ddr_hwdata <= 64'd0;
        end else begin
            dreq_s <= {dreq_s[0], dreq_t};
            case (d_state)
                D_IDLE: begin
                    if (d_pending) begin
                        ddr_haddr  <= bq_addr;
                        ddr_hwrite <= bq_write;
                        ddr_hsize  <= bq_size;
                        ddr_hprot  <= bq_prot;
                        ddr_hwdata <= bq_wdata;
                        ddr_htrans <= HTRANS_NONSEQ;
                        d_state    <= D_AP;
                    end
                end
                D_AP: begin
                    if (ddr_hready) begin
                        ddr_htrans <= HTRANS_IDLE;
                        d_state    <= D_DP;
                    end
                end
                default: begin   // D_DP
                    if (ddr_hready) begin
                        dresp_data <= ddr_hrdata;
                        dresp_err  <= ddr_hresp;
                        dack_t     <= ~dack_t;
                        d_state    <= D_IDLE;
                    end
                end
            endcase
        end
    end

    // =========================================================
    // APB_CLK 側: APB_P*
    // =========================================================
    localparam [1:0] P_IDLE   = 2'd0;
    localparam [1:0] P_SETUP  = 2'd1;
    localparam [1:0] P_ACCESS = 2'd2;

    reg [1:0] p_state;
    reg [1:0] preq_s;
    wire      p_pending = (preq_s[1] != pack_t);

    // 書き込むバイトレーンのマスク (PSTRB の 1 ビットにつき 8 ビット)
    wire [3:0]  apb_strb_sel  = bq_addr[2] ? bq_strb[7:4] : bq_strb[3:0];
    wire [31:0] apb_lane_mask = {{8{apb_strb_sel[3]}}, {8{apb_strb_sel[2]}}, {8{apb_strb_sel[1]}}, {8{apb_strb_sel[0]}}};

    always @(posedge apb_clk or negedge apb_rst_n) begin
        if (!apb_rst_n) begin
            preq_s      <= 2'b00;
            p_state     <= P_IDLE;
            pack_t      <= 1'b0;
            presp_data  <= 32'd0;
            presp_err   <= 1'b0;
            apb_paddr   <= 32'd0;
            apb_psel    <= 1'b0;
            apb_penable <= 1'b0;
            apb_pwrite  <= 1'b0;
            apb_pwdata  <= 32'd0;
            apb_pstrb   <= 4'd0;
            apb_pprot   <= 3'd0;
        end else begin
            preq_s <= {preq_s[0], preq_t};
            case (p_state)
                P_IDLE: begin
                    if (p_pending) begin
                        // PADDR は 4 バイト境界に揃え、PWDATA は書き込むバイトレーンにだけ値を置く (実機で 1 バイトと
                        // 2 バイトの読み書きを観測した形に合わせる)
                        apb_paddr  <= {bq_addr[31:2], 2'b00};
                        apb_pwrite <= bq_write;
                        apb_pwdata <= !bq_write ? 32'd0 : (bq_addr[2] ? bq_wdata[63:32] : bq_wdata[31:0]) & apb_lane_mask;
                        apb_pstrb  <= apb_strb_sel;
                        // PPROT: [0] 特権 (HPROT[1])、[1] 非セキュア (0)、[2] 命令 (HPROT[0] の反転)
                        apb_pprot  <= {~bq_prot[0], 1'b0, bq_prot[1]};
                        apb_psel   <= 1'b1;
                        p_state    <= P_SETUP;
                    end
                end
                P_SETUP: begin
                    apb_penable <= 1'b1;
                    p_state     <= P_ACCESS;
                end
                default: begin   // P_ACCESS
                    if (apb_pready) begin
                        presp_data  <= apb_prdata;
                        presp_err   <= apb_pslverr;
                        apb_psel    <= 1'b0;
                        apb_penable <= 1'b0;
                        pack_t      <= ~pack_t;
                        p_state     <= P_IDLE;
                    end
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // c_htrans[0]: SEQ と BUSY は来ない (Hazard3 は NONSEQ と IDLE だけを出す)
    // extm_htrans[0]: NONSEQ と SEQ は同じに扱い、BUSY と IDLE は受け付けない (HTRANS[1] だけで決まる)
    wire unused = &{c_htrans[0], extm_htrans[0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
