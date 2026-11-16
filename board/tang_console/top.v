// =============================================================
// File:        board/tang_console/top.v
// Module:      ae350_probe_top
// Role:        Tang Console 138K で本物の AE350 を動かし、実機でしか決まらない値を読む構成のトップ (= 2026-11-10)。
//              DDR3 は使わない。命令はブロック RAM の ROM から読み、データとスタックは AE350 の中の DLM に置く
//              (= sw/board.ld)。値は sw/probe.c が UART (= USB シリアル、1,250,000 bps) に出す。
//
//   50 MHz ─▶ ae350_pll ─▶ CORE 800 / DDR 50 / AHB 100 / APB 100 / RTC 10 MHz (= Sipeed のデモと同じ)
//   shell_top (= tb/shell_top.v。シミュレーションと同じ回路で、合成では本物の AE350_SOC につながる)
//     ROM_H*   ─▶ ahb_rom (= 16 KB、中身は ROM_HEX)
//     DDR_H*   ─▶ ahb_sdram ─▶ SDRAM の制御 ─▶ ベースボードの SDRAM0 (= 32 MB)
//                  SDRAM の制御は、定義 SDRAM_HS が無ければ sdram_bridge (= 20 MHz 版)、あれば sdram_ctrl_hs +
//                  sdram_io (= 166.7 MHz 版。2 つ目の PLL。読んだデータを取る位置は SDRAM_IN_DLY / SDRAM_CAP_EDGE / SDRAM_RD_FIRST)
//     EXTM_H*  ─▶ 使わない
//
// Ports:
//   input  wire clk50     50 MHz の発振器
//   input  wire btn0_n    ボタン 0 (= 押すとリセット)
//   input  wire uart_rx   USB シリアルの受信 (= 何か 1 文字送ると、probe.c がもう一度出す)
//   output wire uart_tx   USB シリアルの送信
// =============================================================

`default_nettype none

module ae350_probe_top #(
`ifdef AE350_ROM_HEX
    parameter ROM_HEX = `AE350_ROM_HEX
`else
    parameter ROM_HEX = ""
`endif
) (
    input  wire clk50,
    input  wire btn0_n,
    input  wire uart_rx,
    output wire uart_tx,

    // ベースボードの SDRAM0 (= W9825G6KH、32 MB)
    inout  wire [15:0] sdram_dq,
    output wire [12:0] sdram_addr,
    output wire [1:0]  sdram_ba,
    output wire        sdram_clk,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_dqm
`ifdef AE350_MEM_DDR3
    ,
    // SOM の DDR3 (= H5TQ4G63EFR が 2 個、DQ 32 bit、1 GB)。名前とピンは Sipeed の DDR3 の試験と同じ (= ddr3/ddr3.cst)
    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
`endif
`ifdef AE350_MEM_LITEDRAM
    ,
    // SOM の DDR3 の 2 個 (= DQ 32 bit、1 GB)。LiteDRAM の制御 (= litedram_core) の口の名前のまま (= 実験。
    // ピンは litedram/ddram.cst。1 個目は LiteX-Boards の Tang Console の定義、2 個目は Sipeed の DDR3 の試験の .cst から)
    output wire [14:0] ddram_a,
    output wire [2:0]  ddram_ba,
    output wire        ddram_cas_n,
    output wire        ddram_cke,
    output wire        ddram_clk_n,
    output wire        ddram_clk_p,
    output wire        ddram_cs_n,
    output wire [3:0]  ddram_dm,
    inout  wire [31:0] ddram_dq,
    inout  wire [3:0]  ddram_dqs_n,
    inout  wire [3:0]  ddram_dqs_p,
    output wire        ddram_odt,
    output wire        ddram_ras_n,
    output wire        ddram_reset_n,
    output wire        ddram_we_n
`endif
);

    wire core_clk;
    wire ddr_clk;
    wire ahb_clk;
    wire apb_clk;
    wire rtc_clk;
    wire clk20;
    wire lock;
    wire sclk;              // SDRAM の制御のクロック (= 20 MHz 版は clk20、166.7 MHz 版は s_clk)
    wire lock_all;

`ifdef AE350_CPU_HAZARD3
    // モックの Hazard3 を FPGA のロジックで動かす版: CORE_CLK 40 MHz、AHB_CLK 50 MHz (= 配置配線の Fmax は 41.6 / 53.1 MHz)
    localparam integer CORE_DIV = 20;
    localparam integer AHB_DIV  = 16;
`else
    localparam integer CORE_DIV = 1;
    localparam integer AHB_DIV  = 8;
`endif
    ae350_pll #(.CORE_DIV (CORE_DIV), .AHB_DIV (AHB_DIV)) u_pll (
        .clkin    (clk50),
        .reset    (1'b0),
        .core_clk (core_clk),
        .ddr_clk  (ddr_clk),
        .ahb_clk  (ahb_clk),
        .apb_clk  (apb_clk),
        .rtc_clk  (rtc_clk),
        .sdram_clk (clk20),
        .lock     (lock)
    );

    // ボタンと PLL の lock からリセットを作る (= rtl/reset_gen.v。50 MHz で 10 ms 押されたら、離して 10 ms で解く)
    wire rst_n;

    reset_gen #(
        .PRESS_CYCLES   (500000),
        .RELEASE_CYCLES (500000)
    ) u_reset (
        .clk   (clk50),
        .btn_n (btn0_n),
        .lock  (lock_all),
        .rst_n (rst_n)
    );

`ifdef SDRAM_HS
    // 実機で振って決めた値 (= 2026-11-11。立ち上がり RD_FIRST 12 で、通る遅れは約 45〜310 刻み。その真ん中)。
    // シミュレーション (= ボードの遅れ 0) より、実機ではデータが約 1 サイクル遅れて届く
    `ifndef SDRAM_IN_DLY
        `define SDRAM_IN_DLY 180
    `endif
    `ifndef SDRAM_CAP_EDGE
        `define SDRAM_CAP_EDGE 0
    `endif
    `ifndef SDRAM_RD_FIRST
        `define SDRAM_RD_FIRST 12
    `endif
    // 166.7 MHz 版のクロック (= 2 つ目の PLL。VCO 1000 MHz)
    wire s_clk, lock_hs;
    sdram_pll u_sdram_pll (
        .clkin (clk50), .reset (1'b0), .s_clk (s_clk), .lock (lock_hs)
    );
    assign sclk     = s_clk;
    assign lock_all = lock & lock_hs;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_clk20 = clk20;   // 20 MHz 版の SDRAM のクロック (= 166.7 MHz 版では使わない)
    /* verilator lint_on UNUSEDSIGNAL */
`else
    assign sclk     = clk20;
    assign lock_all = lock;
`endif

    wire        hresetn;
    wire        cpu_txd;
    wire        presetn;
    wire        apb_access;
    wire [31:0] apb_paddr;
    wire [3:0]  misc;
    wire [31:0] rom_haddr;
    wire [1:0]  rom_htrans;
    wire        rom_hwrite;
    wire [31:0] rom_hrdata;
    wire        rom_hready;
    wire        rom_hresp;

    ahb_rom #(
        .WORDS     (4096),
        .INIT_FILE (ROM_HEX)
    ) u_rom (
        .hclk    (ahb_clk),
        .hresetn (hresetn),
        .haddr   (rom_haddr),
        .htrans  (rom_htrans),
        .hwrite  (rom_hwrite),
        .hrdata  (rom_hrdata),
        .hready  (rom_hready),
        .hresp   (rom_hresp)
    );

// ---------------------------------------------------------
// DDR_H* の先: SDRAM (= ahb_sdram → sdram_bridge。シミュレーションの tb_mem の TB_SDRAM と同じ組み方)
// ---------------------------------------------------------
wire [31:0]  ddr_haddr;
wire [1:0]   ddr_htrans;
wire         ddr_hwrite;
wire [2:0]   ddr_hsize;
wire [63:0]  ddr_hwdata;
wire [63:0]  ddr_hrdata;
wire         ddr_hready;
wire         ddr_hresp;

// リセットは、DDR_CLK と SDRAM のクロックのそれぞれで、解くときだけ同期させる。ahb_sdram は非同期、sdram_bridge と
// sdram_ctrl_hs は同期でリセットを受ける (= tb/tb_mem.v の TB_SDRAM と同じ形)
/* verilator lint_off SYNCASYNCNET */
reg [1:0] ddr_rst_s;
reg [1:0] sdram_rst_s;
/* verilator lint_on SYNCASYNCNET */
always @(posedge ddr_clk or negedge rst_n) begin
    if (!rst_n) ddr_rst_s <= 2'b00;
    else        ddr_rst_s <= {ddr_rst_s[0], 1'b1};
end
always @(posedge sclk or negedge rst_n) begin
    if (!rst_n) sdram_rst_s <= 2'b00;
    else        sdram_rst_s <= {sdram_rst_s[0], 1'b1};
end

`ifdef AE350_MEM_DDR3
// ---------------------------------------------------------
// DDR_H* の先: DDR3 (= 2026-11-13、build.sh の MEM=ddr3。ahb_ddr3 → Gowin の DDR3 の IP)
//   50 MHz ─ Gowin_PLL (= 400 MHz、版 B) ─ memory_clk ─┐
//   50 MHz ────────────────────────────────────────── DDR3 の IP ─ clk_out (= 100 MHz) ─ ahb_ddr3 の IP の側
//   部品の名前 (= Gowin_PLL_inst、u_ddr3) と PLL の外側 (= gowin_pll.v、pll_init.v) は、実機で動いた Sipeed の DDR3 の試験と同じ
//   (= ddr3/ddr3.cst の INS_LOC がこの名前を指す)。SDRAM のピンは使わない (= 選ばない状態で止めておく)
// ---------------------------------------------------------
wire         ddr3_memory_clk, ddr3_pll_lock, ddr3_pll_stop, ddr3_clk_x1, ddr3_calib_done;
wire         ddr3_cmd_ready, ddr3_cmd_en, ddr3_wr_data_rdy, ddr3_wr_data_en, ddr3_rd_data_valid;
wire [2:0]   ddr3_cmd;
wire [28:0]  ddr3_addr;
wire [255:0] ddr3_wr_data, ddr3_rd_data;
wire [31:0]  ddr3_wr_data_mask;

/* verilator lint_off PINCONNECTEMPTY */
Gowin_PLL Gowin_PLL_inst (
    .lock     (ddr3_pll_lock),
    .clkout0  (),
    .clkout1  (),
    .clkout2  (ddr3_memory_clk),
    .clkin    (clk50),
    .init_clk (clk50),
    .reset    (!rst_n),
    .enclk0   (1'b1),
    .enclk1   (1'b1),
    .enclk2   (ddr3_pll_stop)
);

DDR3_Memory_Interface_Top u_ddr3 (
    .memory_clk          (ddr3_memory_clk),
    .pll_stop            (ddr3_pll_stop),
    .clk                 (clk50),
    .rst_n               (rst_n),
    .cmd_ready           (ddr3_cmd_ready),
    .cmd                 (ddr3_cmd),
    .cmd_en              (ddr3_cmd_en),
    .addr                (ddr3_addr),
    .wr_data_rdy         (ddr3_wr_data_rdy),
    .wr_data             (ddr3_wr_data),
    .wr_data_en          (ddr3_wr_data_en),
    .wr_data_end         (ddr3_wr_data_en),   // 1:4 なので、1 回の命令のデータは 1 サイクルで終わる (= Sipeed の試験と同じ)
    .wr_data_mask        (ddr3_wr_data_mask),
    .rd_data             (ddr3_rd_data),
    .rd_data_valid       (ddr3_rd_data_valid),
    .rd_data_end         (),
    .sr_req              (1'b0),
    .ref_req             (1'b0),
    .sr_ack              (),
    .ref_ack             (),
    .init_calib_complete (ddr3_calib_done),
    .clk_out             (ddr3_clk_x1),
    .pll_lock            (ddr3_pll_lock),
    .burst               (1'b0),
    .ddr_rst             (),
    .O_ddr_addr          (ddr_addr),
    .O_ddr_ba            (ddr_bank),
    .O_ddr_cs_n          (ddr_cs),
    .O_ddr_ras_n         (ddr_ras),
    .O_ddr_cas_n         (ddr_cas),
    .O_ddr_we_n          (ddr_we),
    .O_ddr_clk           (ddr_ck),
    .O_ddr_clk_n         (ddr_ck_n),
    .O_ddr_cke           (ddr_cke),
    .O_ddr_odt           (ddr_odt),
    .O_ddr_reset_n       (ddr_reset_n),
    .O_ddr_dqm           (ddr_dm),
    .IO_ddr_dq           (ddr_dq),
    .IO_ddr_dqs          (ddr_dqs),
    .IO_ddr_dqs_n        (ddr_dqs_n)
);
/* verilator lint_on PINCONNECTEMPTY */

ahb_ddr3 u_ahb_ddr3 (
    .hclk          (ddr_clk),
    .hresetn       (ddr_rst_s[1]),
    .haddr         (ddr_haddr),
    .htrans        (ddr_htrans),
    .hwrite        (ddr_hwrite),
    .hsize         (ddr_hsize),
    .hwdata        (ddr_hwdata),
    .hrdata        (ddr_hrdata),
    .hreadyout     (ddr_hready),
    .hresp         (ddr_hresp),
    .cclk          (ddr3_clk_x1),
    .calib_done    (ddr3_calib_done),
    .cmd_ready     (ddr3_cmd_ready),
    .cmd           (ddr3_cmd),
    .cmd_en        (ddr3_cmd_en),
    .addr          (ddr3_addr),
    .wr_data_rdy   (ddr3_wr_data_rdy),
    .wr_data       (ddr3_wr_data),
    .wr_data_en    (ddr3_wr_data_en),
    .wr_data_mask  (ddr3_wr_data_mask),
    .rd_data       (ddr3_rd_data),
    .rd_data_valid (ddr3_rd_data_valid)
);

// SDRAM のピンは使わない (= 選ばない状態で止めておく)
assign sdram_dq    = 16'hzzzz;
assign sdram_addr  = 13'd0;
assign sdram_ba    = 2'd0;
assign sdram_clk   = 1'b0;
assign sdram_cs_n  = 1'b1;
assign sdram_ras_n = 1'b1;
assign sdram_cas_n = 1'b1;
assign sdram_we_n  = 1'b1;
assign sdram_dqm   = 2'b11;
/* verilator lint_off UNUSEDSIGNAL */
wire unused_ddr3 = &{1'b0, sclk, sdram_rst_s[1]};
/* verilator lint_on UNUSEDSIGNAL */
`elsif AE350_MEM_LITEDRAM
// ---------------------------------------------------------
// DDR_H* の先: LiteDRAM の DDR3 の制御 (= 2026-11-16、実験。build.sh の MEM=litedram。ahb_litedram → litedram_core)
//   litedram_core は litedram_gen (= board/tang_console/litedram/tang_console.yml) で書き出したもので、PLL、PHY、制御、初期化と
//   調整を行う VexRiscv を中に持つ。初期化と調整が済むと init_done が立つ。それまでは、ボードの UART に litedram_core の
//   出力 (= 115,200 bps、初期化の記録) を出す (= 下の uart_tx)
// ---------------------------------------------------------
wire          ld_clk, ld_rst, ld_init_done, ld_uart_tx;
wire          ld_cmd_valid, ld_cmd_ready, ld_cmd_we, ld_wdata_valid, ld_wdata_ready, ld_rdata_valid, ld_rdata_ready;
wire [24:0]   ld_cmd_addr;
wire [255:0]  ld_wdata_data, ld_rdata_data;
wire [31:0]   ld_wdata_we;

/* verilator lint_off PINCONNECTEMPTY */
litedram_core u_litedram (
    .clk                            (clk50),
    .rst                            (!rst_n),
    .uart_rx                        (1'b1),
    .uart_tx                        (ld_uart_tx),
    .pll_locked                     (),
    .init_done                      (ld_init_done),
    .init_error                     (),
    .user_clk                       (ld_clk),
    .user_rst                       (ld_rst),
    .ddram_a                        (ddram_a),
    .ddram_ba                       (ddram_ba),
    .ddram_cas_n                    (ddram_cas_n),
    .ddram_cke                      (ddram_cke),
    .ddram_clk_n                    (ddram_clk_n),
    .ddram_clk_p                    (ddram_clk_p),
    .ddram_cs_n                     (ddram_cs_n),
    .ddram_dm                       (ddram_dm),
    .ddram_dq                       (ddram_dq),
    .ddram_dqs_n                    (ddram_dqs_n),
    .ddram_dqs_p                    (ddram_dqs_p),
    .ddram_odt                      (ddram_odt),
    .ddram_ras_n                    (ddram_ras_n),
    .ddram_reset_n                  (ddram_reset_n),
    .ddram_we_n                     (ddram_we_n),
    .user_port_native_0_cmd_addr    (ld_cmd_addr),
    .user_port_native_0_cmd_ready   (ld_cmd_ready),
    .user_port_native_0_cmd_valid   (ld_cmd_valid),
    .user_port_native_0_cmd_we      (ld_cmd_we),
    .user_port_native_0_rdata_data  (ld_rdata_data),
    .user_port_native_0_rdata_ready (ld_rdata_ready),
    .user_port_native_0_rdata_valid (ld_rdata_valid),
    .user_port_native_0_wdata_data  (ld_wdata_data),
    .user_port_native_0_wdata_ready (ld_wdata_ready),
    .user_port_native_0_wdata_valid (ld_wdata_valid),
    .user_port_native_0_wdata_we    (ld_wdata_we)
);
/* verilator lint_on PINCONNECTEMPTY */

ahb_litedram #(.MEM_AW (30), .LINE_AW (5)) u_ahb_litedram (   // DDR3 2 個 (= 1 GB、1 語 32 byte)
    .hclk        (ddr_clk),
    .hresetn     (ddr_rst_s[1]),
    .haddr       (ddr_haddr),
    .htrans      (ddr_htrans),
    .hwrite      (ddr_hwrite),
    .hsize       (ddr_hsize),
    .hwdata      (ddr_hwdata),
    .hrdata      (ddr_hrdata),
    .hreadyout   (ddr_hready),
    .hresp       (ddr_hresp),
    .cclk        (ld_clk),
    .crst_n      (ld_init_done && !ld_rst),
    .cmd_valid   (ld_cmd_valid),
    .cmd_ready   (ld_cmd_ready),
    .cmd_we      (ld_cmd_we),
    .cmd_addr    (ld_cmd_addr),
    .wdata_valid (ld_wdata_valid),
    .wdata_ready (ld_wdata_ready),
    .wdata_data  (ld_wdata_data),
    .wdata_we    (ld_wdata_we),
    .rdata_valid (ld_rdata_valid),
    .rdata_ready (ld_rdata_ready),
    .rdata_data  (ld_rdata_data)
);

// SDRAM のピンは使わない (= 選ばない状態で止めておく)
assign sdram_dq    = 16'hzzzz;
assign sdram_addr  = 13'd0;
assign sdram_ba    = 2'd0;
assign sdram_clk   = 1'b0;
assign sdram_cs_n  = 1'b1;
assign sdram_ras_n = 1'b1;
assign sdram_cas_n = 1'b1;
assign sdram_we_n  = 1'b1;
assign sdram_dqm   = 2'b11;
/* verilator lint_off UNUSEDSIGNAL */
wire unused_litedram = &{1'b0, sclk, sdram_rst_s[1]};
/* verilator lint_on UNUSEDSIGNAL */
`else
wire          s_fill_valid, s_fill_ready, s_we, s_wready, s_init_done;
wire [20:0]   s_fill_line;
wire [127:0]  s_fill_data;
wire [24:0]   s_waddr;
wire [7:0]    s_wdata;

ahb_sdram #(.SDRAM_AW(25)) u_ahb_sdram (
    .hclk       (ddr_clk),
    .hresetn    (ddr_rst_s[1]),
    .haddr      (ddr_haddr),
    .htrans     (ddr_htrans),
    .hwrite     (ddr_hwrite),
    .hsize      (ddr_hsize),
    .hwdata     (ddr_hwdata),
    .hrdata     (ddr_hrdata),
    .hreadyout  (ddr_hready),
    .hresp      (ddr_hresp),
    .sclk       (sclk),
    .srst_n     (sdram_rst_s[1]),
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
// 166.7 MHz 版 (= 制御は sdram_ctrl_hs、ピンは sdram_io。SDRAM のクロックも sdram_io が出す)
wire [3:0]  io_cmd;
wire [12:0] io_addr;
wire [1:0]  io_ba, io_dqm;
wire [15:0] io_dq_out, io_dq_in;
wire        io_dq_oe;

sdram_ctrl_hs #(.ADDR_WIDTH (25), .RD_FIRST (`SDRAM_RD_FIRST)) u_sdram_ctrl (
    .clk (s_clk), .rst_n (sdram_rst_s[1]), .fill_valid (s_fill_valid), .fill_line (s_fill_line), .fill_ready (s_fill_ready),
    .fill_data (s_fill_data), .we (s_we), .waddr (s_waddr), .wdata (s_wdata), .wready (s_wready), .init_done (s_init_done),
    .io_cmd (io_cmd), .io_addr (io_addr), .io_ba (io_ba), .io_dqm (io_dqm), .io_dq_out (io_dq_out), .io_dq_oe (io_dq_oe),
    .io_dq_in (io_dq_in)
);

sdram_io #(.IN_DLY (`SDRAM_IN_DLY), .CAP_EDGE (`SDRAM_CAP_EDGE)) u_sdram_io (
    .s_clk (s_clk), .cmd (io_cmd), .addr (io_addr), .ba (io_ba), .dqm (io_dqm), .dq_out (io_dq_out),
    .dq_oe (io_dq_oe), .dq_in (io_dq_in), .sdram_dq (sdram_dq), .sdram_addr (sdram_addr), .sdram_ba (sdram_ba),
    .sdram_clk (sdram_clk), .sdram_cs_n (sdram_cs_n), .sdram_ras_n (sdram_ras_n), .sdram_cas_n (sdram_cas_n),
    .sdram_we_n (sdram_we_n), .sdram_dqm (sdram_dqm)
);
`else
sdram_bridge #(.ADDR_WIDTH(25)) u_sdram_bridge (
    .clk         (clk20),
    .rst_n       (sdram_rst_s[1]),
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
    .sdram_addr  (sdram_addr),
    .sdram_ba    (sdram_ba),
    .sdram_cs_n  (sdram_cs_n),
    .sdram_ras_n (sdram_ras_n),
    .sdram_cas_n (sdram_cas_n),
    .sdram_we_n  (sdram_we_n),
    .sdram_dqm   (sdram_dqm)
);

// SDRAM は命令の半 cycle 後に受ける (= rtl/sdram_bridge.v)
assign sdram_clk = ~clk20;

`endif

/* verilator lint_off UNUSEDSIGNAL */
wire unused_sdram = s_init_done;
/* verilator lint_on UNUSEDSIGNAL */
`endif   // AE350_MEM_DDR3

    /* verilator lint_off PINCONNECTEMPTY */
    // UART は 1,250,000 bps (= APB_CLK 100 MHz ÷ 8 ÷ 10。ボードの USB シリアル (= BL616) を通ることを確かめた速さ)
    shell_top #(.UART_PRESCALE (16'd10)) u_top (
        .core_clk       (core_clk),
        .ahb_clk        (ahb_clk),
        .apb_clk        (apb_clk),
        .ddr_clk        (ddr_clk),
        .rtc_clk        (rtc_clk),
        .rst_n          (rst_n),
        .uart_tx        (cpu_txd),
        .uart_rx        (uart_rx),
        .hresetn        (hresetn),
        .dbg_presetn    (presetn),
        .dbg_apb_access (apb_access),
        .dbg_apb_paddr  (apb_paddr),
        .dbg_misc       (misc),

        .rom_haddr      (rom_haddr),
        .rom_htrans     (rom_htrans),
        .rom_hwrite     (rom_hwrite),
        .rom_hrdata     (rom_hrdata),
        .rom_hready     (rom_hready),
        .rom_hresp      (rom_hresp),

        .ddr_haddr      (ddr_haddr),
        .ddr_htrans     (ddr_htrans),
        .ddr_hwrite     (ddr_hwrite),
        .ddr_hsize      (ddr_hsize),
        .ddr_hwdata     (ddr_hwdata),
        .ddr_hrdata     (ddr_hrdata),
        .ddr_hready     (ddr_hready),
        .ddr_hresp      (ddr_hresp),

        .extm_hsel      (1'b0),
        .extm_haddr     (32'd0),
        .extm_htrans    (2'b00),
        .extm_hburst    (3'd0),
        .extm_hwrite    (1'b0),
        .extm_hsize     (3'd0),
        .extm_hprot     (4'd0),
        .extm_hwdata    (64'd0),
        .extm_hrdata    (),
        .extm_hreadyout (),
        .extm_hresp     ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

`ifdef AE350_NO_OBSERVER
    // ROM がローダーのとき (= build.sh の ROM=loader): UART は CPU だけが使う (= ローダーが待っている間に OBS の行が流れ、
    // 返事と重なると返事が落ちるため)
`ifdef AE350_MEM_LITEDRAM
    // LiteDRAM の版は、LiteDRAM の初期化と調整が済むまで、その出力 (= 115,200 bps) を出す (= 済まなければ、記録が見える)
    assign uart_tx = ld_init_done ? cpu_txd : ld_uart_tx;
`else
    assign uart_tx = cpu_txd;
`endif
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_obs = &{presetn, apb_access, apb_paddr, misc};   // 観測の回路に渡す信号 (= 外したので使わない)
    /* verilator lint_on UNUSEDSIGNAL */
`else
    // 見張り (= CPU の文字が 0.1 秒以上途切れたとき、約 1 秒ごとに状態を 1 行出す)。それ以外は CPU の文字をそのまま出す
    ae350_observer u_obs (
        .clk50       (clk50),
        .lock        (lock),
        .rst_n       (rst_n),
        .ahb_clk     (ahb_clk),
        .hresetn     (hresetn),
        .rom_htrans1 (rom_htrans[1]),
        .rom_haddr   (rom_haddr),
        .apb_clk     (apb_clk),
        .presetn     (presetn),
        .apb_access  (apb_access),
        .apb_paddr   (apb_paddr),
        .cpu_txd     (cpu_txd),
        .misc        (misc),
        .txd         (obs_txd),
        .active      (obs_active)
    );

    wire obs_txd;
    wire obs_active;
    assign uart_tx = obs_active ? obs_txd : cpu_txd;
`endif

endmodule

`default_nettype wire
