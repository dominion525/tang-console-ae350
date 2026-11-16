// =============================================================
// File:        rtl/AE350_SOC.v
// Module:      AE350_SOC
// Role:        GW5AST に内蔵された RISC-V ハードコア AE350 の Hazard3 の版 (= 同じポートを持ち、中の CPU を Hazard3 にしたもの)。
//              Gowin の AE350_SOC プリミティブ (= simlib/gw5a/prim_sim.v) とポートの名前・向き・幅が同じ。
//              シミュレーションでは prim_sim.v の代わりにこのファイルを読み、トップモジュールは
//              シミュレーションでも合成でも同じ記述で AE350_SOC をインスタンス化する。
//              実機には載らない (= 合成では本物のプリミティブが使われる)。
//
//              段 1 (= 2026-11-08): ポートだけを持ち、出力は固定値。
//              段 2 (= 2026-11-08): Hazard3 (1port 版) とアドレスデコーダを入れ、ROM_H* と DDR_H* に転送を出す。
//              段 3 (= 2026-11-09): AHB-APB ブリッジを入れ、APB_P* に転送を出す。
//              段 4 (= 2026-11-10): PLMT と PLIC を入れ、Hazard3 のタイマ割り込みと外部割り込みにつなぐ。
//              段 4 の後 (= 2026-11-10): クロックを本物と同じ関係にした (= CPU は CORE_CLK、各ポートはそのクロック)。
//
// Ports:       prim_sim.v の AE350_SOC と同じ (= tools/check_ports.rb で比べる)。
//              主なもの:
//   input  POR_N / HW_RSTN            リセット (= どちらも active low)
//   input  CORE_CLK                   CPU (= Hazard3) のクロック
//   input  AHB_CLK                    ROM_H*、PLIC、PLMT のクロック
//   input  APB_CLK                    APB_P* のクロック
//   input  DDR_CLK                    DDR_H* のクロック
//   output ROM_H*   (32 bit)          命令メモリへの AHB。読み出し専用で HSIZE / HBURST / HWDATA が無い
//   output DDR_H*   (64 bit)          データメモリへの AHB
//   output EXTS_H*  (32 bit)          FPGA のロジック側の周辺回路への AHB (= 0xE800_0000〜)
//   output APB_P*   (32 bit)          FPGA のロジック側の周辺回路への APB (= 0xF800_0000〜)
//   input  EXTM_H*  (64 bit)          FPGA のロジック側から AE350 のアドレス空間 (= DDR、ILM / DLM ほか) への AHB
//   input  GP_INT   (16 本)           ユーザーの割り込み
//
// Reset:       POR_N と HW_RSTN の AND を、クロックごとに同期させる (= かかるのは非同期、解けるのは同期。
//              rtl/ae350_reset_sync.v)。HRESETN は AHB_CLK、PRESETN は APB_CLK、DDR_RSTN は DDR_CLK に同期した
//              もの。Hazard3 は CORE_CLK に同期したリセットを使う
// Clock:       CORE_CLK / AHB_CLK / APB_CLK / DDR_CLK は互いに非同期として扱い、どの比でも動く
//              (= リファレンスデザインは CORE 800、AHB 100、APB 100、DDR 50 MHz を 1 つの PLL から出し、SDC では
//              互いに非同期として扱う。周波数比の制約は資料に無い)
//
// Testbench:
//   tb/shell_top.v   AE350_SOC をインスタンス化した確認用のトップ (= lint 用)
//   tb/tb_mem.v      ROM と DDR のメモリモデルをつなぎ、プログラムを流す TB
//   make check / make test
//
// Design Notes:
//   - バス (= rtl/ae350_fabric.v): Hazard3 の AHB を受け、アドレスで行き先を決めて、行き先のクロックの
//     側で転送する。転送は同時に 1 つだけで、クロックの間はトグルのハンドシェイクで乗せ換える
//       0x8000_0000〜0x8FFF_FFFF の読み出し → ROM_H* (= AHB_CLK)
//       0x0000_0000〜0x7FFF_FFFF            → DDR_H* (= DDR_CLK)
//       0xF800_0000〜0xFBFF_FFFF            → APB_P* (= APB_CLK)
//       0xE400_0000〜0xE5FF_FFFF            → Hazard3 の版の中の PLIC (= AHB_CLK。Andes NCEPLIC100 と同じ挙動。rtl/ae350_plic.v)
//       0xE600_0000〜0xE60F_FFFF            → Hazard3 の版の中の PLMT (= AHB_CLK。rtl/ae350_plmt.v)
//       それ以外、ROM の範囲への書き込み     → バスの入口でエラー応答 (= 2 サイクルの HRESP = 1)
//   - ROM_H*: HADDR は Hazard3 のアドレスをそのまま出す (= 下位 2 bit も)。読み出しは常に 32 bit。ROM_HWRITE は常に 0
//   - DDR_H*: 書き込みは 32 bit の値を上下の 32 bit に同じように並べる。読み出しは HADDR[2] で上下を選ぶ。
//     HSIZE / HPROT はそのまま、HBURST は SINGLE
//   - APB_P*: SETUP の次から ACCESS を出し、PREADY を待つ。PSLVERR = 1 は AHB のエラー応答に変える。
//     PADDR はアドレスをそのまま出す (= 本物が上位のビットを落とすかは資料に無い。FPGA 側の回路は上位を見ない形にしてある)。
//     PSTRB は HSIZE と HADDR[1:0] から作り、読み出しでは 0
//   - 割り込み: PLMT の mtip と PLIC の meip を CORE_CLK に 2 段で同期させ、Hazard3 の timer_irq と irq (= mip.MEIP)
//     につなぐ。PLMT の mtime は AHB_CLK で 1 サイクルごとに進む (= Gowin の BSP とデモは、mtime がバスの
//     クロック (= 100 MHz) で進む前提)。RTC_CLK は使わない。GP_INT は AHB_CLK に 2 段で同期させ、GP0 → ソース 4、
//     GP1〜GP15 → ソース 11〜25 (= MUG1029 表 4-2) に入れる。PLIC-SWINT (= ソフトウェア割り込み) は入れない
//   - EXTS_H*: 0xE800_0000〜0xEFFF_FFFF を AHB_CLK の 32 bit の AHB として出す (= 段 5)。HADDR はフルアドレス
//     (= 第三者の設計 2 件が 0xE800_xxxx と比べている)。HREADYIN はスレーブの HREADYOUT
//   - ILM / DLM: 0xA000_0000 と 0xA020_0000 に 64 KB ずつ (= 段 5、Hazard3 の版の中のメモリ)
//   - EXTM_H*: AHB_CLK の 64 bit のスレーブとして受け、中央のバスに乗せる (= 段 5)。行き先は CPU と同じアドレス空間
//     全体で、中央のバスが CPU と交互に 1 つずつ処理する。HBURST は見ない
//   - UART は Hazard3 の版に入れない (= FPGA のロジック側に作る)。UART2_TXD は 1 (= アイドル) に固定する
//   - 使わない入力は lint_off UNUSEDSIGNAL で囲む
// =============================================================

`default_nettype none

module AE350_SOC (
    input  wire        POR_N,
    input  wire        HW_RSTN,
    input  wire        CORE_CLK,
    input  wire        DDR_CLK,
    input  wire        AHB_CLK,
    input  wire        APB_CLK,
    input  wire        DBG_TCK,
    input  wire        RTC_CLK,
    input  wire        CORE_CE,
    input  wire        AXI_CE,
    input  wire        DDR_CE,
    input  wire        AHB_CE,
    input  wire [7:0]  APB_CE,
    input  wire        APB2AHB_CE,
    output wire        PRESETN,
    output wire        HRESETN,
    output wire        DDR_RSTN,

    input  wire [15:0] GP_INT,
    input  wire [7:0]  DMA_REQ,
    output wire [7:0]  DMA_ACK,

    output wire        CORE0_WFI_MODE,
    input  wire        WAKEUP_IN,
    output wire        RTC_WAKEUP,
    input  wire        SCAN_TEST,
    input  wire        SCAN_EN,
    input  wire        TEST_CLK,
    input  wire        TEST_MODE,
    input  wire        TEST_RSTN,

    // 命令メモリへの AHB (= 読み出し専用)
    output wire [31:0] ROM_HADDR,
    input  wire [31:0] ROM_HRDATA,
    input  wire        ROM_HREADY,
    input  wire        ROM_HRESP,
    output wire [1:0]  ROM_HTRANS,
    output wire        ROM_HWRITE,

    // FPGA のロジック側への APB
    output wire [31:0] APB_PADDR,
    output wire        APB_PENABLE,
    input  wire [31:0] APB_PRDATA,
    input  wire        APB_PREADY,
    output wire        APB_PSEL,
    output wire [31:0] APB_PWDATA,
    output wire        APB_PWRITE,
    input  wire        APB_PSLVERR,
    output wire [2:0]  APB_PPROT,
    output wire [3:0]  APB_PSTRB,

    // FPGA のロジック側への AHB (= AE350 がマスタ)
    input  wire [31:0] EXTS_HRDATA,
    input  wire        EXTS_HREADYIN,
    input  wire        EXTS_HRESP,
    output wire [31:0] EXTS_HADDR,
    output wire [2:0]  EXTS_HBURST,
    output wire [3:0]  EXTS_HPROT,
    output wire        EXTS_HSEL,
    output wire [2:0]  EXTS_HSIZE,
    output wire [1:0]  EXTS_HTRANS,
    output wire [31:0] EXTS_HWDATA,
    output wire        EXTS_HWRITE,

    // FPGA のロジック側から AE350 のアドレス空間への AHB (= AE350 がスレーブ)
    input  wire [31:0] EXTM_HADDR,
    input  wire [2:0]  EXTM_HBURST,
    input  wire [3:0]  EXTM_HPROT,
    output wire [63:0] EXTM_HRDATA,
    input  wire        EXTM_HREADY,
    output wire        EXTM_HREADYOUT,
    output wire        EXTM_HRESP,
    input  wire        EXTM_HSEL,
    input  wire [2:0]  EXTM_HSIZE,
    input  wire [1:0]  EXTM_HTRANS,
    input  wire [63:0] EXTM_HWDATA,
    input  wire        EXTM_HWRITE,

    // データメモリへの AHB
    output wire [31:0] DDR_HADDR,
    output wire [2:0]  DDR_HBURST,
    output wire [3:0]  DDR_HPROT,
    input  wire [63:0] DDR_HRDATA,
    input  wire        DDR_HREADY,
    input  wire        DDR_HRESP,
    output wire [2:0]  DDR_HSIZE,
    output wire [1:0]  DDR_HTRANS,
    output wire [63:0] DDR_HWDATA,
    output wire        DDR_HWRITE,

    // JTAG
    input  wire        TMS_IN,
    input  wire        TRST_IN,
    input  wire        TDI_IN,
    output wire        TDO_OUT,
    output wire        TDO_OE,

    // SPI
    input  wire        SPI2_HOLDN_IN,
    input  wire        SPI2_WPN_IN,
    input  wire        SPI2_CLK_IN,
    input  wire        SPI2_CSN_IN,
    input  wire        SPI2_MISO_IN,
    input  wire        SPI2_MOSI_IN,
    output wire        SPI2_HOLDN_OUT,
    output wire        SPI2_HOLDN_OE,
    output wire        SPI2_WPN_OUT,
    output wire        SPI2_WPN_OE,
    output wire        SPI2_CLK_OUT,
    output wire        SPI2_CLK_OE,
    output wire        SPI2_CSN_OUT,
    output wire        SPI2_CSN_OE,
    output wire        SPI2_MISO_OUT,
    output wire        SPI2_MISO_OE,
    output wire        SPI2_MOSI_OUT,
    output wire        SPI2_MOSI_OE,

    // I2C
    input  wire        I2C_SCL_IN,
    input  wire        I2C_SDA_IN,
    output wire        I2C_SCL,
    output wire        I2C_SDA,

    // UART1
    output wire        UART1_TXD,
    output wire        UART1_RTSN,
    input  wire        UART1_RXD,
    input  wire        UART1_CTSN,
    input  wire        UART1_DSRN,
    input  wire        UART1_DCDN,
    input  wire        UART1_RIN,
    output wire        UART1_DTRN,
    output wire        UART1_OUT1N,
    output wire        UART1_OUT2N,

    // UART2
    output wire        UART2_TXD,
    output wire        UART2_RTSN,
    input  wire        UART2_RXD,
    input  wire        UART2_CTSN,
    input  wire        UART2_DCDN,
    input  wire        UART2_DSRN,
    input  wire        UART2_RIN,
    output wire        UART2_DTRN,
    output wire        UART2_OUT1N,
    output wire        UART2_OUT2N,

    // PIT
    output wire        CH0_PWM,
    output wire        CH0_PWMOE,
    output wire        CH1_PWM,
    output wire        CH1_PWMOE,
    output wire        CH2_PWM,
    output wire        CH2_PWMOE,
    output wire        CH3_PWM,
    output wire        CH3_PWMOE,

    // 内蔵 SRAM の設定
    input  wire        PGEN_CHAIN_I,
    output wire        PRDYN_CHAIN_O,
    input  wire [2:0]  EMA,
    input  wire [1:0]  EMAW,
    input  wire        EMAS,
    input  wire        RET1N,
    input  wire        RET2N,

    // MBIST
    input  wire [19:0] SCAN_IN,
    input  wire        INTEG_TCK,
    input  wire        INTEG_TDI,
    input  wire        INTEG_TMS,
    input  wire        INTEG_TRST,
    output wire        INTEG_TDO,
    output wire [19:0] SCAN_OUT,

    // GPIO
    input  wire [31:0] GPIO_IN,
    output wire [31:0] GPIO_OE,
    output wire [31:0] GPIO_OUT
);

    // ---------------------------------------------------------
    // リセット: クロックごとに、かかるのは非同期・解けるのはクロックに同期 (= 2 段)
    // ---------------------------------------------------------
    wire rst_n = POR_N & HW_RSTN;

    wire core_rst_n;
    wire ahb_rst_n;
    wire apb_rst_n;
    wire ddr_rst_n;

    ae350_reset_sync u_rst_core (.clk(CORE_CLK), .rst_n_in(rst_n), .rst_n_out(core_rst_n));
    ae350_reset_sync u_rst_ahb  (.clk(AHB_CLK),  .rst_n_in(rst_n), .rst_n_out(ahb_rst_n));
    ae350_reset_sync u_rst_apb  (.clk(APB_CLK),  .rst_n_in(rst_n), .rst_n_out(apb_rst_n));
    ae350_reset_sync u_rst_ddr  (.clk(DDR_CLK),  .rst_n_in(rst_n), .rst_n_out(ddr_rst_n));

    assign HRESETN  = ahb_rst_n;
    assign PRESETN  = apb_rst_n;
    assign DDR_RSTN = ddr_rst_n;

    // ---------------------------------------------------------
    // CPU (= Hazard3、1port 版、CORE_CLK)
    // ---------------------------------------------------------
    wire [31:0] haddr;
    wire        hwrite;
    wire [1:0]  htrans;
    wire [2:0]  hsize;
    wire [2:0]  hburst;
    wire [3:0]  hprot;
    wire [31:0] hwdata;
    wire        hready;
    wire        hresp;
    wire [31:0] hrdata;

    wire        pwrup_req;
    wire        unblock_out;

    // 割り込み (= AHB_CLK の PLMT / PLIC から来るので、CORE_CLK に 2 段で同期させる)
    wire        mtip;
    wire        meip;
    reg  [1:0]  mtip_s;
    reg  [1:0]  meip_s;
    always @(posedge CORE_CLK or negedge core_rst_n) begin
        if (!core_rst_n) begin
            mtip_s <= 2'b00;
            meip_s <= 2'b00;
        end else begin
            mtip_s <= {mtip_s[0], mtip};
            meip_s <= {meip_s[0], meip};
        end
    end

    /* verilator lint_off PINCONNECTEMPTY */
    hazard3_cpu_1port #(
        .RESET_VECTOR       (32'h8000_0000),
        .MTVEC_INIT         (32'h8000_0000),
        .EXTENSION_A        (1),
        .EXTENSION_C        (1),
        .EXTENSION_M        (1),
        .EXTENSION_ZIFENCEI (1),
        .CSR_COUNTER        (1),     // mcycle / minstret (= A25 も持つ標準のカウンタ)
`ifdef AE350_HAZARD3_FAST
        // 最適化した版 (= 2026-11-13。FPGA のロジックで動かす版で、Hazard3 の速さの選択肢と Zb* の拡張を全部入れて比べるため。
        // build.sh の CPU=hazard3-fast。A25 に無い命令を持つので、AE350 との互換性は無くなる)
        .BRANCH_PREDICTOR   (1),
        .MUL_FAST           (1),
        .MUL_FASTER         (1),
        .MULH_FAST          (1),
        .EXTENSION_ZBA      (1),
        .EXTENSION_ZBB      (1),
        .EXTENSION_ZBC      (1),
        .EXTENSION_ZBKB     (1),
        .EXTENSION_ZBS      (1),
`endif
        // 識別子は実機の A25 と同じ値 (= Tang Console で読んだ。2026-11-10)。misa は Hazard3 のまま (= F / D は無い)
        .MVENDORID_VAL      (32'h0000_031E),
        .MARCHID_VAL        (32'h8000_0A25),
        .MIMPID_OVERRIDE    (1),
        .MIMPID_VAL         (32'h0000_0160)
    ) u_cpu (
        .clk                        (CORE_CLK),
        .clk_always_on              (CORE_CLK),
        .rst_n                      (core_rst_n),

        .pwrup_req                  (pwrup_req),
        .pwrup_ack                  (pwrup_req),
        .clk_en                     (),
        .unblock_out                (unblock_out),
        .unblock_in                 (unblock_out),

        .haddr                      (haddr),
        .hwrite                     (hwrite),
        .htrans                     (htrans),
        .hsize                      (hsize),
        .hburst                     (hburst),
        .hprot                      (hprot),
        .hmastlock                  (),
        .hmaster                    (),
        .hexcl                      (),
        .hready                     (hready),
        .hresp                      (hresp),
        .hexokay                    (1'b1),
        .hwdata                     (hwdata),
        .hrdata                     (hrdata),

        .fence_i_vld                (),
        .fence_d_vld                (),
        .fence_rdy                  (1'b1),

        .dbg_req_halt               (1'b0),
        .dbg_req_halt_on_reset      (1'b0),
        .dbg_req_resume             (1'b0),
        .dbg_halted                 (),
        .dbg_running                (),
        .dbg_data0_rdata            (32'd0),
        .dbg_data0_wdata            (),
        .dbg_data0_wen              (),
        .dbg_instr_data             (32'd0),
        .dbg_instr_data_vld         (1'b0),
        .dbg_instr_data_rdy         (),
        .dbg_instr_caught_exception (),
        .dbg_instr_caught_ebreak    (),

        .dbg_sbus_addr              (32'd0),
        .dbg_sbus_write             (1'b0),
        .dbg_sbus_size              (2'd0),
        .dbg_sbus_vld               (1'b0),
        .dbg_sbus_rdy               (),
        .dbg_sbus_err               (),
        .dbg_sbus_wdata             (32'd0),
        .dbg_sbus_rdata             (),

        .mhartid_val                (32'd0),
        .eco_version                (4'd0),

        .irq                        (meip_s[1]),
        .soft_irq                   (1'b0),
        .timer_irq                  (mtip_s[1])
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------------------------------------------------
    // バス (= ae350_fabric): 行き先ごとのクロックで転送する
    // ---------------------------------------------------------
    wire        plic_wen;
    wire        plic_ren;
    wire        plmt_wen;
    wire [21:0] reg_addr;
    wire [31:0] reg_wdata;
    wire [3:0]  reg_wstrb;
    wire [31:0] plic_rdata;
    wire [31:0] plmt_rdata;

    ae350_fabric u_fabric (
        .core_clk    (CORE_CLK),
        .core_rst_n  (core_rst_n),
        .c_haddr     (haddr),
        .c_hwrite    (hwrite),
        .c_htrans    (htrans),
        .c_hsize     (hsize),
        .c_hprot     (hprot),
        .c_hwdata    (hwdata),
        .c_hready    (hready),
        .c_hresp     (hresp),
        .c_hrdata    (hrdata),

        .ahb_clk     (AHB_CLK),
        .ahb_rst_n   (ahb_rst_n),
        .rom_haddr   (ROM_HADDR),
        .rom_htrans  (ROM_HTRANS),
        .rom_hrdata  (ROM_HRDATA),
        .rom_hready  (ROM_HREADY),
        .rom_hresp   (ROM_HRESP),
        .plic_wen    (plic_wen),
        .plic_ren    (plic_ren),
        .plmt_wen    (plmt_wen),
        .reg_addr    (reg_addr),
        .reg_wdata   (reg_wdata),
        .reg_wstrb   (reg_wstrb),
        .plic_rdata  (plic_rdata),
        .plmt_rdata  (plmt_rdata),
        .exts_haddr  (EXTS_HADDR),
        .exts_htrans (EXTS_HTRANS),
        .exts_hsel   (EXTS_HSEL),
        .exts_hwrite (EXTS_HWRITE),
        .exts_hsize  (EXTS_HSIZE),
        .exts_hprot  (EXTS_HPROT),
        .exts_hwdata (EXTS_HWDATA),
        .exts_hrdata (EXTS_HRDATA),
        .exts_hready (EXTS_HREADYIN),
        .exts_hresp  (EXTS_HRESP),
        .extm_hsel      (EXTM_HSEL),
        .extm_haddr     (EXTM_HADDR),
        .extm_htrans    (EXTM_HTRANS),
        .extm_hwrite    (EXTM_HWRITE),
        .extm_hsize     (EXTM_HSIZE),
        .extm_hprot     (EXTM_HPROT),
        .extm_hwdata    (EXTM_HWDATA),
        .extm_hready    (EXTM_HREADY),
        .extm_hrdata    (EXTM_HRDATA),
        .extm_hreadyout (EXTM_HREADYOUT),
        .extm_hresp     (EXTM_HRESP),

        .ddr_clk     (DDR_CLK),
        .ddr_rst_n   (ddr_rst_n),
        .ddr_haddr   (DDR_HADDR),
        .ddr_htrans  (DDR_HTRANS),
        .ddr_hwrite  (DDR_HWRITE),
        .ddr_hsize   (DDR_HSIZE),
        .ddr_hprot   (DDR_HPROT),
        .ddr_hwdata  (DDR_HWDATA),
        .ddr_hrdata  (DDR_HRDATA),
        .ddr_hready  (DDR_HREADY),
        .ddr_hresp   (DDR_HRESP),

        .apb_clk     (APB_CLK),
        .apb_rst_n   (apb_rst_n),
        .apb_paddr   (APB_PADDR),
        .apb_psel    (APB_PSEL),
        .apb_penable (APB_PENABLE),
        .apb_pwrite  (APB_PWRITE),
        .apb_pwdata  (APB_PWDATA),
        .apb_pstrb   (APB_PSTRB),
        .apb_pprot   (APB_PPROT),
        .apb_prdata  (APB_PRDATA),
        .apb_pready  (APB_PREADY),
        .apb_pslverr (APB_PSLVERR)
    );

    assign ROM_HWRITE = 1'b0;
    assign DDR_HBURST = 3'b000;      // SINGLE (= Hazard3 も SINGLE しか出さない)

    // ---------------------------------------------------------
    // PLMT と PLIC (= AHB_CLK)
    // ---------------------------------------------------------
    ae350_plmt u_plmt (
        .clk     (AHB_CLK),
        .rst_n   (ahb_rst_n),
        .wen     (plmt_wen),
        .addr    (reg_addr[5:0]),
        .wdata   (reg_wdata),
        .wstrb   (reg_wstrb),
        .rdata   (plmt_rdata),
        .mtip    (mtip)
    );

    // GP_INT は FPGA のロジック側から来るので、AHB_CLK に 2 段で同期させる。
    // GP0 → ソース 4、GP1〜GP15 → ソース 11〜25 (= MUG1029 表 4-2)。ほかのソースは使わない
    reg  [15:0] gp_int_s1;
    reg  [15:0] gp_int_s2;
    always @(posedge AHB_CLK or negedge ahb_rst_n) begin
        if (!ahb_rst_n) begin
            gp_int_s1 <= 16'd0;
            gp_int_s2 <= 16'd0;
        end else begin
            gp_int_s1 <= GP_INT;
            gp_int_s2 <= gp_int_s1;
        end
    end

    wire [31:1] plic_src = {6'd0, gp_int_s2[15:1], 6'd0, gp_int_s2[0], 3'd0};

    /* verilator lint_off UNUSEDSIGNAL */
    wire plic_seip;
    /* verilator lint_on UNUSEDSIGNAL */

    ae350_plic u_plic (
        .clk   (AHB_CLK),
        .rst_n (ahb_rst_n),
        .src   (plic_src),
        .wen   (plic_wen),
        .ren   (plic_ren),
        .addr  (reg_addr),
        .wdata (reg_wdata),
        .wstrb (reg_wstrb),
        .rdata (plic_rdata),
        .meip  (meip),
        .seip  (plic_seip)     // S モードへの通知 (= Hazard3 に S モードが無いので使わない)
    );

    assign EXTS_HBURST = 3'b000;      // SINGLE (= Hazard3 も SINGLE しか出さない)


    // ---------------------------------------------------------
    // 使わない周辺回路の出力
    // ---------------------------------------------------------
    assign DMA_ACK        = 8'd0;
    assign CORE0_WFI_MODE = 1'b0;
    assign RTC_WAKEUP     = 1'b0;

    assign TDO_OUT = 1'b0;
    assign TDO_OE  = 1'b0;

    assign SPI2_HOLDN_OUT = 1'b0;
    assign SPI2_HOLDN_OE  = 1'b0;
    assign SPI2_WPN_OUT   = 1'b0;
    assign SPI2_WPN_OE    = 1'b0;
    assign SPI2_CLK_OUT   = 1'b0;
    assign SPI2_CLK_OE    = 1'b0;
    assign SPI2_CSN_OUT   = 1'b0;
    assign SPI2_CSN_OE    = 1'b0;
    assign SPI2_MISO_OUT  = 1'b0;
    assign SPI2_MISO_OE   = 1'b0;
    assign SPI2_MOSI_OUT  = 1'b0;
    assign SPI2_MOSI_OE   = 1'b0;

    assign I2C_SCL = 1'b0;
    assign I2C_SDA = 1'b0;

    assign UART1_TXD   = 1'b0;
    assign UART1_RTSN  = 1'b0;
    assign UART1_DTRN  = 1'b0;
    assign UART1_OUT1N = 1'b0;
    assign UART1_OUT2N = 1'b0;

    // UART2 は Hazard3 の版に入れない。TXD はアイドルの 1 に固定する
    assign UART2_TXD   = 1'b1;
    assign UART2_RTSN  = 1'b0;
    assign UART2_DTRN  = 1'b0;
    assign UART2_OUT1N = 1'b0;
    assign UART2_OUT2N = 1'b0;

    assign CH0_PWM   = 1'b0;
    assign CH0_PWMOE = 1'b0;
    assign CH1_PWM   = 1'b0;
    assign CH1_PWMOE = 1'b0;
    assign CH2_PWM   = 1'b0;
    assign CH2_PWMOE = 1'b0;
    assign CH3_PWM   = 1'b0;
    assign CH3_PWMOE = 1'b0;

    assign PRDYN_CHAIN_O = 1'b0;
    assign INTEG_TDO     = 1'b0;
    assign SCAN_OUT      = 20'd0;

    assign GPIO_OE  = 32'd0;
    assign GPIO_OUT = 32'd0;

    // ---------------------------------------------------------
    // 使わない入力
    // ---------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_inputs = &{
        DBG_TCK, RTC_CLK,
        CORE_CE, AXI_CE, DDR_CE, AHB_CE, APB_CE, APB2AHB_CE,
        DMA_REQ, WAKEUP_IN,
        SCAN_TEST, SCAN_EN, TEST_CLK, TEST_MODE, TEST_RSTN,
        EXTM_HBURST,
        TMS_IN, TRST_IN, TDI_IN,
        SPI2_HOLDN_IN, SPI2_WPN_IN, SPI2_CLK_IN, SPI2_CSN_IN, SPI2_MISO_IN, SPI2_MOSI_IN,
        I2C_SCL_IN, I2C_SDA_IN,
        UART1_RXD, UART1_CTSN, UART1_DSRN, UART1_DCDN, UART1_RIN,
        UART2_RXD, UART2_CTSN, UART2_DCDN, UART2_DSRN, UART2_RIN,
        PGEN_CHAIN_I, EMA, EMAW, EMAS, RET1N, RET2N,
        SCAN_IN, INTEG_TCK, INTEG_TDI, INTEG_TMS, INTEG_TRST,
        GPIO_IN, hburst
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
