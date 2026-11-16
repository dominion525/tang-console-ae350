// =============================================================
// File:        tb/shell_top.v
// Module:      shell_top
// Role:        AE350_SOC をインスタンス化した確認用のトップ (= 段 1、2026-11-08。段 2 で ROM_H* / DDR_H* を外に出した)。
//              全ポートを名前で接続する。制御用の入力は、実機で使う値 (= Sipeed のデモの IP の出力と
//              同じ値) を与える。
//              シミュレーションではモック (rtl/AE350_SOC.v) とつながり、合成では本物の
//              プリミティブとつながる記述にしてある。
//
// Ports:
//   input  wire core_clk   CORE_CLK (= リファレンスデザインは 800 MHz)
//   input  wire ahb_clk    AHB_CLK (= 100 MHz)。ROM_H* と、AE350 の中の PLIC / PLMT のクロック
//   input  wire apb_clk    APB_CLK (= 100 MHz)。APB_P* と、その先の UART / GP_INT のレジスタのクロック
//   input  wire ddr_clk    DDR_CLK (= 50 MHz)。DDR_H* のクロック
//   input  wire rtc_clk    RTC_CLK に与えるクロック (= 本物では内蔵の RTC が使う。モックは使わない。PLMT の mtime は AHB_CLK で進む)
//   input  wire rst_n      HW_RSTN に与えるリセット (active low)。POR_N は 1 に固定する。UART の合図 (= rtl/uart_reset_seq.v)
//                          でも HW_RSTN にリセットを入れる (= 固まったプログラムから ROM のローダーへ戻す。2026-11-12)
//   output wire uart_tx    APB_P* の先の UART (= rtl/apb_uart.v、段 3) の送信。AE350 の UART2_TXD は使わない
//   input  wire uart_rx    同じ UART の受信 (= 段 3b)。アイドルは 1。AE350 の UART2_RXD は使わない
//   output wire hresetn    AE350_SOC が出す AHB 側のリセット
//   rom_h*                 ROM_H* をそのまま外に出す (= 命令メモリは外に置く)
//   ddr_h*                 DDR_H* のうち HADDR / HTRANS / HWRITE / HSIZE / HWDATA / HRDATA / HREADY / HRESP を外に出す
//
// Testbench:
//   make check    (= lint)
//   tb/tb_mem.v      (= メモリモデルをつないでプログラムを流す)
//
// Design Notes:
//   - APB_P* の先に、UART (= 段 3、0xF800_0000)、GP_INT を立てるレジスタ (= 段 4、0xF800_1000)、届いた PADDR を
//     読み返すレジスタ (= 実機の値を読む構成、0xF800_F000) を置く。
//     どちらにも当たらないアドレスは PSLVERR を返す。PRESETN を周辺回路のリセットに使う
//   - EXTS_H* の先に 4 KB の RAM (= rtl/ahb_sram.v、段 5) を置く。EXTS_WAIT でデータフェーズの待ちを選ぶ
//   - EXTM_H* は外に出す (= マスタは外に置く。EXTM_HREADY には EXTM_HREADYOUT を返す。Falcon の設計と同じ形)
//   - DDR_HBURST / DDR_HPROT は外に出さない (= 段 2 のメモリモデルは使わない)
//   - 使わない出力は空の接続にし、lint_off PINCONNECTEMPTY で囲む
//   - APB_CE は Sipeed のデモの値 (= 8'b10110101)。各ビットがどの周辺回路かは確かめていない
// =============================================================

`default_nettype none

module shell_top #(
    parameter [15:0]  UART_PRESCALE = 16'd108,    // 1 bit の長さ ÷ 8 (= 100 MHz で 115200 bps)
    parameter integer EXTS_WAIT     = 0            // EXTS_H* の先の RAM のデータフェーズの待ち
) (
    input  wire        core_clk,
    input  wire        ahb_clk,
    input  wire        apb_clk,
    input  wire        ddr_clk,
    input  wire        rtc_clk,
    input  wire        rst_n,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire        hresetn,

    // 実機で見張るための出力 (= board/tang_console/ae350_observer.v。シミュレーションでは使わない)
    output wire        dbg_presetn,
    output wire        dbg_apb_access,
    output wire [31:0] dbg_apb_paddr,
    output wire [3:0]  dbg_misc,       // {DDR_RSTN, CORE0_WFI_MODE, RTC_WAKEUP, PRDYN_CHAIN_O}

    // 命令メモリへの AHB (= ROM_H*)
    output wire [31:0] rom_haddr,
    output wire [1:0]  rom_htrans,
    output wire        rom_hwrite,
    input  wire [31:0] rom_hrdata,
    input  wire        rom_hready,
    input  wire        rom_hresp,

    // データメモリへの AHB (= DDR_H*)
    output wire [31:0] ddr_haddr,
    output wire [1:0]  ddr_htrans,
    output wire        ddr_hwrite,
    output wire [2:0]  ddr_hsize,
    output wire [63:0] ddr_hwdata,
    input  wire [63:0] ddr_hrdata,
    input  wire        ddr_hready,
    input  wire        ddr_hresp,

    // FPGA 側のマスタから AE350 へ (= EXTM_H*、AHB_CLK、64 bit)。マスタは外に置く (= TB ではモデル)
    input  wire        extm_hsel,
    input  wire [31:0] extm_haddr,
    input  wire [1:0]  extm_htrans,
    input  wire [2:0]  extm_hburst,
    input  wire        extm_hwrite,
    input  wire [2:0]  extm_hsize,
    input  wire [3:0]  extm_hprot,
    input  wire [63:0] extm_hwdata,
    output wire [63:0] extm_hrdata,
    output wire        extm_hreadyout,
    output wire        extm_hresp
);

    // ---------------------------------------------------------
    // APB_P* の先: アドレスデコーダと周辺回路
    //   0xF800_0000〜0xF800_0FFF  UART (= apb_uart)
    //   0xF800_1000〜0xF800_1FFF  GP_INT を立てるレジスタ (= apb_gpint)
    //   0xF800_F000〜0xF800_FFFF  届いた PADDR を読み返すレジスタ (= apb_paddr_probe。実機で PADDR の形を確かめる)
    //   それ以外                   PSLVERR = 1 (= 待たせずにエラーを返す)
    // ---------------------------------------------------------
    wire        presetn;
    wire [31:0] apb_paddr;
    wire        apb_penable;
    wire [31:0] apb_prdata;
    wire        apb_pready;
    wire        apb_psel;
    wire [31:0] apb_pwdata;
    wire        apb_pwrite;
    wire        apb_pslverr;
    wire [3:0]  apb_pstrb;

    assign dbg_presetn    = presetn;
    // AE350 の APB_P* (= ae_apb_*) とデコーダ (= apb_*) の間を、レジスタで区切る (= rtl/apb_reg_slice.v。
    // 実機で、PADDR からデコーダを通って AE350 に戻る経路が APB_CLK に収まらなかった)
    wire [31:0] ae_apb_paddr;
    wire        ae_apb_penable;
    wire [31:0] ae_apb_prdata;
    wire        ae_apb_pready;
    wire        ae_apb_psel;
    wire [31:0] ae_apb_pwdata;
    wire        ae_apb_pwrite;
    wire        ae_apb_pslverr;
    wire [3:0]  ae_apb_pstrb;

    apb_reg_slice u_apb_slice (
        .clk       (apb_clk),
        .rst_n     (presetn),
        .m_psel    (ae_apb_psel),
        .m_penable (ae_apb_penable),
        .m_pwrite  (ae_apb_pwrite),
        .m_paddr   (ae_apb_paddr),
        .m_pwdata  (ae_apb_pwdata),
        .m_pstrb   (ae_apb_pstrb),
        .m_prdata  (ae_apb_prdata),
        .m_pready  (ae_apb_pready),
        .m_pslverr (ae_apb_pslverr),
        .s_psel    (apb_psel),
        .s_penable (apb_penable),
        .s_pwrite  (apb_pwrite),
        .s_paddr   (apb_paddr),
        .s_pwdata  (apb_pwdata),
        .s_pstrb   (apb_pstrb),
        .s_prdata  (apb_prdata),
        .s_pready  (apb_pready),
        .s_pslverr (apb_pslverr)
    );

    assign dbg_apb_access = ae_apb_psel && ae_apb_penable;
    assign dbg_apb_paddr  = ae_apb_paddr;

    wire        sel_uart  = (apb_paddr[25:12] == 14'd0);
    wire        sel_gpint = (apb_paddr[25:12] == 14'd1);
    wire        sel_probe = (apb_paddr[25:12] == 14'h00F);

    wire [31:0] uart_prdata;
    wire        uart_pready;
    wire        uart_pslverr;
    wire [31:0] gpint_prdata;
    wire        gpint_pready;
    wire        gpint_pslverr;
    wire [15:0] gp_int;
    wire [31:0] probe_prdata;
    wire        probe_pready;
    wire        probe_pslverr;

    assign apb_prdata  = sel_uart  ? uart_prdata  : sel_gpint ? gpint_prdata  : sel_probe ? probe_prdata  : 32'd0;
    assign apb_pready  = sel_uart  ? uart_pready  : sel_gpint ? gpint_pready  : sel_probe ? probe_pready  : 1'b1;
    assign apb_pslverr = sel_uart  ? uart_pslverr : sel_gpint ? gpint_pslverr : sel_probe ? probe_pslverr : (apb_psel && apb_penable);

    wire seq_hold;       // apb_uart の CTRL の bit 0 (= ROM のローダーが中身を受けている間は 1。uart_reset_seq の hold へ)
    apb_uart #(
        .PRESCALE (UART_PRESCALE)
    ) u_uart (
        .clk     (apb_clk),
        .rst_n   (presetn),
        .psel    (apb_psel && sel_uart),
        .penable (apb_penable),
        .pwrite  (apb_pwrite),
        .paddr   (apb_paddr),
        .pwdata  (apb_pwdata),
        .pstrb   (apb_pstrb),
        .prdata  (uart_prdata),
        .pready  (uart_pready),
        .pslverr (uart_pslverr),
        .txd     (uart_tx),
        .rxd     (uart_rx),
        .seq_hold (seq_hold)
    );

    apb_gpint u_gpint (
        .clk     (apb_clk),
        .rst_n   (presetn),
        .psel    (apb_psel && sel_gpint),
        .penable (apb_penable),
        .pwrite  (apb_pwrite),
        .paddr   (apb_paddr),
        .pwdata  (apb_pwdata),
        .pstrb   (apb_pstrb),
        .prdata  (gpint_prdata),
        .pready  (gpint_pready),
        .pslverr (gpint_pslverr),
        .gp_int  (gp_int)
    );

    apb_paddr_probe u_probe (
        .clk     (apb_clk),
        .rst_n   (presetn),
        .psel    (apb_psel && sel_probe),
        .penable (apb_penable),
        .pwrite  (apb_pwrite),
        .paddr   (apb_paddr),
        .pwdata  (apb_pwdata),
        .pstrb   (apb_pstrb),
        .prdata  (probe_prdata),
        .pready  (probe_pready),
        .pslverr (probe_pslverr)
    );

    // ---------------------------------------------------------
    // EXTS_H* の先: 4 KB の RAM (= 0xE800_0000〜0xE800_0FFF。その外の EXTS_H* の範囲はエラー応答)
    // EXTS_H* は AHB_CLK で動く (= Gowin の AE350 の資料)
    // ---------------------------------------------------------
    wire [31:0] exts_haddr;
    wire [1:0]  exts_htrans;
    wire        exts_hsel;
    wire        exts_hwrite;
    wire [2:0]  exts_hsize;
    wire [31:0] exts_hwdata;
    wire [31:0] exts_hrdata;
    wire        exts_hreadyout;
    wire        exts_hresp;

    // AE350 の EXTS_H* (= ae_exts_*) と RAM (= exts_*) の間を、レジスタで区切る (= rtl/ahb_reg_slice.v。
    // 実機で、RAM の HREADYOUT から AE350 を通って HSEL が戻る経路が AHB_CLK に収まらなかった)
    wire [31:0] ae_exts_haddr;
    wire [1:0]  ae_exts_htrans;
    wire        ae_exts_hsel;
    wire        ae_exts_hwrite;
    wire [2:0]  ae_exts_hsize;
    wire [31:0] ae_exts_hwdata;
    wire [31:0] ae_exts_hrdata;
    wire        ae_exts_hreadyout;
    wire        ae_exts_hresp;

    ahb_reg_slice u_exts_slice (
        .clk         (ahb_clk),
        .rst_n       (hresetn),
        .m_hsel      (ae_exts_hsel),
        .m_haddr     (ae_exts_haddr),
        .m_htrans    (ae_exts_htrans),
        .m_hwrite    (ae_exts_hwrite),
        .m_hsize     (ae_exts_hsize),
        .m_hwdata    (ae_exts_hwdata),
        .m_hrdata    (ae_exts_hrdata),
        .m_hreadyout (ae_exts_hreadyout),
        .m_hresp     (ae_exts_hresp),
        .s_hsel      (exts_hsel),
        .s_haddr     (exts_haddr),
        .s_htrans    (exts_htrans),
        .s_hwrite    (exts_hwrite),
        .s_hsize     (exts_hsize),
        .s_hwdata    (exts_hwdata),
        .s_hrdata    (exts_hrdata),
        .s_hreadyout (exts_hreadyout),
        .s_hresp     (exts_hresp)
    );

    ahb_sram #(
        .WORDS (1024),
        .WAIT  (EXTS_WAIT)
    ) u_exts_ram (
        .hclk      (ahb_clk),
        .hresetn   (hresetn),
        .hsel      (exts_hsel),
        .hready    (exts_hreadyout),     // スレーブが 1 つなので、バスの HREADY = このスレーブの HREADYOUT
        .haddr     (exts_haddr),
        .htrans    (exts_htrans),
        .hwrite    (exts_hwrite),
        .hsize     (exts_hsize),
        .hwdata    (exts_hwdata),
        .hrdata    (exts_hrdata),
        .hreadyout (exts_hreadyout),
        .hresp     (exts_hresp)
    );

    // UART の合図で AE350 をリセットする (= 合図の見張りは rst_n でだけリセットし、自分のリセットではリセットしない)
    wire seq_rst_n;
    uart_reset_seq #(.PRESCALE (UART_PRESCALE)) u_reset_seq (
        .clk       (apb_clk),
        .rst_n     (rst_n),
        .rxd       (uart_rx),
        .hold      (seq_hold),
        .rst_out_n (seq_rst_n)
    );

    /* verilator lint_off PINCONNECTEMPTY */
    AE350_SOC u_ae350 (
        .POR_N          (1'b1),      // LiteX の gowin_ae350 と tang-phosphor と同じく 1 にし、リセットは HW_RSTN だけでかける
        .HW_RSTN        (rst_n & seq_rst_n),
        .CORE_CLK       (core_clk),
        .DDR_CLK        (ddr_clk),
        .AHB_CLK        (ahb_clk),
        .APB_CLK        (apb_clk),
        .DBG_TCK        (1'b1),     // JTAG を使わないときの値 (= LiteX の gowin_ae350 と tang-phosphor と同じ)
        .RTC_CLK        (rtc_clk),
        .CORE_CE        (1'b1),
        .AXI_CE         (1'b1),
        .DDR_CE         (1'b1),
        .AHB_CE         (1'b1),
        .APB_CE         (8'b10110101),
        .APB2AHB_CE     (1'b1),
        .PRESETN        (presetn),
        .HRESETN        (hresetn),
        .DDR_RSTN       (dbg_misc[3]),

        .GP_INT         (gp_int),
        .DMA_REQ        (8'd0),
        .DMA_ACK        (),

        .CORE0_WFI_MODE (dbg_misc[2]),
        .WAKEUP_IN      (1'b0),
        .RTC_WAKEUP     (dbg_misc[1]),
        .SCAN_TEST      (1'b0),
        .SCAN_EN        (1'b0),
        .TEST_CLK       (1'b0),
        .TEST_MODE      (1'b0),
        .TEST_RSTN      (1'b1),

        .ROM_HADDR      (rom_haddr),
        .ROM_HRDATA     (rom_hrdata),
        .ROM_HREADY     (rom_hready),
        .ROM_HRESP      (rom_hresp),
        .ROM_HTRANS     (rom_htrans),
        .ROM_HWRITE     (rom_hwrite),

        .APB_PADDR      (ae_apb_paddr),
        .APB_PENABLE    (ae_apb_penable),
        .APB_PRDATA     (ae_apb_prdata),
        .APB_PREADY     (ae_apb_pready),
        .APB_PSEL       (ae_apb_psel),
        .APB_PWDATA     (ae_apb_pwdata),
        .APB_PWRITE     (ae_apb_pwrite),
        .APB_PSLVERR    (ae_apb_pslverr),
        .APB_PPROT      (),
        .APB_PSTRB      (ae_apb_pstrb),

        .EXTS_HRDATA    (ae_exts_hrdata),
        .EXTS_HREADYIN  (ae_exts_hreadyout),
        .EXTS_HRESP     (ae_exts_hresp),
        .EXTS_HADDR     (ae_exts_haddr),
        .EXTS_HBURST    (),
        .EXTS_HPROT     (),
        .EXTS_HSEL      (ae_exts_hsel),
        .EXTS_HSIZE     (ae_exts_hsize),
        .EXTS_HTRANS    (ae_exts_htrans),
        .EXTS_HWDATA    (ae_exts_hwdata),
        .EXTS_HWRITE    (ae_exts_hwrite),

        .EXTM_HADDR     (extm_haddr),
        .EXTM_HBURST    (extm_hburst),
        .EXTM_HPROT     (extm_hprot),
        .EXTM_HRDATA    (extm_hrdata),
        .EXTM_HREADY    (extm_hreadyout),      // マスタもスレーブも 1 つなので、HREADYOUT をそのまま返す
        .EXTM_HREADYOUT (extm_hreadyout),
        .EXTM_HRESP     (extm_hresp),
        .EXTM_HSEL      (extm_hsel),
        .EXTM_HSIZE     (extm_hsize),
        .EXTM_HTRANS    (extm_htrans),
        .EXTM_HWDATA    (extm_hwdata),
        .EXTM_HWRITE    (extm_hwrite),

        .DDR_HADDR      (ddr_haddr),
        .DDR_HBURST     (),
        .DDR_HPROT      (),
        .DDR_HRDATA     (ddr_hrdata),
        .DDR_HREADY     (ddr_hready),
        .DDR_HRESP      (ddr_hresp),
        .DDR_HSIZE      (ddr_hsize),
        .DDR_HTRANS     (ddr_htrans),
        .DDR_HWDATA     (ddr_hwdata),
        .DDR_HWRITE     (ddr_hwrite),

        .TMS_IN         (1'b1),
        .TRST_IN        (1'b1),     // 0 は JTAG のリセット。0 だと実機の AE350 は HRESETN / PRESETN を解かなかった (= 2026-11-10)
        .TDI_IN         (1'b0),
        .TDO_OUT        (),
        .TDO_OE         (),

        .SPI2_HOLDN_IN  (1'b1),
        .SPI2_WPN_IN    (1'b1),
        .SPI2_CLK_IN    (1'b0),
        .SPI2_CSN_IN    (1'b1),
        .SPI2_MISO_IN   (1'b0),
        .SPI2_MOSI_IN   (1'b0),
        .SPI2_HOLDN_OUT (),
        .SPI2_HOLDN_OE  (),
        .SPI2_WPN_OUT   (),
        .SPI2_WPN_OE    (),
        .SPI2_CLK_OUT   (),
        .SPI2_CLK_OE    (),
        .SPI2_CSN_OUT   (),
        .SPI2_CSN_OE    (),
        .SPI2_MISO_OUT  (),
        .SPI2_MISO_OE   (),
        .SPI2_MOSI_OUT  (),
        .SPI2_MOSI_OE   (),

        .I2C_SCL_IN     (1'b1),
        .I2C_SDA_IN     (1'b1),
        .I2C_SCL        (),
        .I2C_SDA        (),

        .UART1_TXD      (),
        .UART1_RTSN     (),
        .UART1_RXD      (1'b1),
        .UART1_CTSN     (1'b0),
        .UART1_DSRN     (1'b0),
        .UART1_DCDN     (1'b0),
        .UART1_RIN      (1'b1),
        .UART1_DTRN     (),
        .UART1_OUT1N    (),
        .UART1_OUT2N    (),

        .UART2_TXD      (),
        .UART2_RTSN     (),
        .UART2_RXD      (1'b1),
        .UART2_CTSN     (1'b0),
        .UART2_DCDN     (1'b0),
        .UART2_DSRN     (1'b0),
        .UART2_RIN      (1'b1),
        .UART2_DTRN     (),
        .UART2_OUT1N    (),
        .UART2_OUT2N    (),

        .CH0_PWM        (),
        .CH0_PWMOE      (),
        .CH1_PWM        (),
        .CH1_PWMOE      (),
        .CH2_PWM        (),
        .CH2_PWMOE      (),
        .CH3_PWM        (),
        .CH3_PWMOE      (),

        .PGEN_CHAIN_I   (1'b1),
        .PRDYN_CHAIN_O  (dbg_misc[0]),
        .EMA            (3'b011),
        .EMAW           (2'b01),
        .EMAS           (1'b0),
        .RET1N          (1'b1),
        .RET2N          (1'b1),

        .SCAN_IN        (20'hFFFFF),   // LiteX の gowin_ae350 と同じ値
        .INTEG_TCK      (1'b0),
        .INTEG_TDI      (1'b0),
        .INTEG_TMS      (1'b0),
        .INTEG_TRST     (1'b0),
        .INTEG_TDO      (),
        .SCAN_OUT       (),

        .GPIO_IN        (32'd0),
        .GPIO_OE        (),
        .GPIO_OUT       ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

endmodule

`default_nettype wire
