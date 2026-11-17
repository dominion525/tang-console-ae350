// =============================================================
// File:        rtl/apb_uart.v
// Module:      apb_uart
// Role:        AE350 の APB_P* の先に置く UART。
//              ファブリック側の回路で、実機でもそのまま使う (本物の AE350 を使う構成でも使う)。
//              送信回路と受信回路には、rtl/vendor/verilog-uart/ の uart_tx.v と uart_rx.v (MIT。変更せずに取り込んだもの) を
//              使う。受信した文字は、RX_DEPTH 文字の FIFO に溜める。
//
// Registers (PADDR[3:2] で選ぶ。上位のビットは見ない):
//   0x00  DATA     書き込むと、下位 8 ビットを 1 文字送信する。送信待ちの文字が残っていると、空くまで PREADY を 0 にする。
//                  読み出すと、受信した 1 文字を FIFO から取り出す (空なら 0 を返し、何も取り出さない)
//   0x04  STATUS   読み出し専用 (書き込みは無視する)
//                  bit 0  送信: 次の文字を待たずに受け付けられる
//                  bit 1  送信: 送信中 (送信待ちの文字か、送信途中の文字がある)
//                  bit 2  受信: FIFO に文字がある
//                  bit 3  受信: FIFO があふれて文字を失った (STATUS を読むと 0 に戻る)
//                  bit 4  受信: ストップビットが 0 の文字を受信して捨てた (STATUS を読むと 0 に戻る)
//   0x08  CTRL     R/W。bit 0 が 1 の間、リセットシーケンス (rtl/uart_reset_seq.v) を監視しない (ROM のローダーがデータを
//                  受信している間に 1 にする。データにシーケンスの 8 バイトが含まれていても、リセットがかからない)
//   それ以外       PSLVERR = 1 を返す
//
// Ports:
//   input  wire        clk / rst_n
//   input  wire        psel / penable / pwrite
//   input  wire [31:0] paddr / pwdata
//   input  wire [3:0]  pstrb       DATA への書き込みは、pstrb[0] が 1 のときだけ文字を送信する
//   output wire [31:0] prdata
//   output wire        pready / pslverr
//   output wire        txd         アイドル時は 1
//   input  wire        rxd         ピンから非同期に入る。2 段の FF で同期化してから受信回路に渡す
//   output wire        seq_hold    CTRL の bit 0 (uart_reset_seq の hold へ)
//
// Parameters:
//   PRESCALE   1 ビットの長さ ÷ 8 (uart_tx と uart_rx の prescale)。100 MHz で 115200 bps なら 108
//   RX_DEPTH   受信 FIFO の深さ (2 のべき乗)。既定値 256 (ローダーがプログラムを受信するときの余裕。16 では、
//              シミュレーションで Hazard3 版のローダーの読み出しが追いつかず、FIFO があふれた)
//
// Clock:       clk (APB_CLK と同じクロック)
// Reset:       rst_n (アクティブ Low、非同期)。uart_tx と uart_rx (同期リセット) には、rst_n を 1 段の FF で受けたものを
//              与える
// =============================================================

`default_nettype none

module apb_uart #(
    parameter [15:0]  PRESCALE = 16'd108,
    parameter integer RX_DEPTH = 256
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output wire        txd,
    input  wire        rxd,
    output wire        seq_hold
);

    localparam [1:0]   REG_DATA   = 2'd0;
    localparam [1:0]   REG_STATUS = 2'd1;
    localparam [1:0]   REG_CTRL   = 2'd2;
    localparam integer RX_AW      = $clog2(RX_DEPTH);

    wire [1:0] reg_sel   = paddr[3:2];
    wire       reg_known = (reg_sel == REG_DATA) || (reg_sel == REG_STATUS) || (reg_sel == REG_CTRL);

    // uart_tx と uart_rx は同期リセット。rst_n (非同期) を 1 段の FF で受けて与える
    // (アサートは非同期、解除はクロックに同期)
    reg sync_rst;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_rst <= 1'b1;
        else        sync_rst <= 1'b0;
    end

    // ---------------------------------------------------------
    // APB のアクセス
    // ---------------------------------------------------------
    wire access      = psel && penable;
    wire done        = access && pready;          // このサイクルで転送が終わる
    wire tx_write    = access && pwrite && reg_sel == REG_DATA && pstrb[0];
    wire rx_read     = done && !pwrite && reg_sel == REG_DATA;
    wire status_read = done && !pwrite && reg_sel == REG_STATUS;
    wire ctrl_write  = done && pwrite && reg_sel == REG_CTRL && pstrb[0];

    // CTRL
    reg ctrl_hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ctrl_hold <= 1'b0;
        else if (ctrl_write) ctrl_hold <= pwdata[0];
    end
    assign seq_hold = ctrl_hold;

    // ---------------------------------------------------------
    // 送信: 送信待ちの文字 (1 文字分)
    // ---------------------------------------------------------
    reg  [7:0] hold_data;
    reg        hold_valid;
    wire       tx_ready;
    wire       tx_busy;

    wire tx_stall = tx_write && hold_valid;

    assign pready  = !tx_stall;
    assign pslverr = access && !reg_known;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_data  <= 8'd0;
            hold_valid <= 1'b0;
        end else begin
            if (hold_valid && tx_ready) hold_valid <= 1'b0;
            if (tx_write && !hold_valid) begin
                hold_data  <= pwdata[7:0];
                hold_valid <= 1'b1;
            end
        end
    end

    uart_tx #(
        .DATA_WIDTH (8)
    ) u_tx (
        .clk           (clk),
        .rst           (sync_rst),
        .s_axis_tdata  (hold_data),
        .s_axis_tvalid (hold_valid),
        .s_axis_tready (tx_ready),
        .txd           (txd),
        .busy          (tx_busy),
        .prescale      (PRESCALE)
    );

    // ---------------------------------------------------------
    // 受信: ピンの同期化、受信回路、FIFO
    // ---------------------------------------------------------
    reg [1:0] rxd_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rxd_sync <= 2'b11;
        else        rxd_sync <= {rxd_sync[0], rxd};
    end

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_frame_error;

    /* verilator lint_off PINCONNECTEMPTY */
    uart_rx #(
        .DATA_WIDTH (8)
    ) u_rx (
        .clk           (clk),
        .rst           (sync_rst),
        .m_axis_tdata  (rx_data),
        .m_axis_tvalid (rx_valid),
        .m_axis_tready (1'b1),          // 受信したらすぐ FIFO に移す
        .rxd           (rxd_sync[1]),
        .busy          (),
        .overrun_error (),              // tready が常に 1 なので発生しない
        .frame_error   (rx_frame_error),
        .prescale      (PRESCALE)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    reg [7:0]     rx_fifo [0:RX_DEPTH-1];
    reg [RX_AW:0] rx_wptr;               // 1 ビット多く持ち、満杯と空を区別する
    reg [RX_AW:0] rx_rptr;
    reg           rx_overrun;
    reg           rx_frame;

    wire rx_empty = (rx_wptr == rx_rptr);
    wire rx_full  = (rx_wptr[RX_AW-1:0] == rx_rptr[RX_AW-1:0]) && (rx_wptr[RX_AW] != rx_rptr[RX_AW]);
    wire rx_push  = rx_valid && !rx_full;
    wire rx_pop   = rx_read && !rx_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_wptr    <= {(RX_AW+1){1'b0}};
            rx_rptr    <= {(RX_AW+1){1'b0}};
            rx_overrun <= 1'b0;
            rx_frame   <= 1'b0;
        end else begin
            if (rx_push) begin
                rx_wptr <= rx_wptr + 1'b1;
            end
            if (rx_pop) begin
                rx_rptr <= rx_rptr + 1'b1;
            end
            // STATUS を読むと 0 に戻る。同じサイクルに新しく発生したら 1 のまま
            if (status_read) begin
                rx_overrun <= 1'b0;
                rx_frame   <= 1'b0;
            end
            if (rx_valid && rx_full) rx_overrun <= 1'b1;
            if (rx_frame_error)      rx_frame   <= 1'b1;
        end
    end

    // FIFO の先頭の 1 文字を、あらかじめレジスタに読んでおく (RX_DEPTH を 256 にしたとき、DATA の読み出しで rx_rptr から
    // 256 個を選ぶ回路が APB の経路に入り、APB_CLK のスラックが 0.016 ns になったため)。
    //   rx_ram_q  毎サイクル rx_fifo[rx_rptr] を読む (同期読み出し。ブロック RAM として推論できる形)
    //   rx_byp    空の FIFO に書き込んだ文字が、そのまま先頭になるとき (書き込んだサイクルの読み出しは古い値なので、バイパスで渡す)
    // 取り出した (rx_pop) 後、次の先頭がレジスタに出るのは 2 サイクル後。APB の転送には SETUP と ACCESS の 2 サイクルが
    // 必要なので、次の DATA の読み出しには間に合う
    reg [7:0] rx_ram_q;
    reg [7:0] rx_byp;
    reg       rx_byp_use;
    always @(posedge clk) begin
        if (rx_push) rx_fifo[rx_wptr[RX_AW-1:0]] <= rx_data;
        rx_ram_q <= rx_fifo[rx_rptr[RX_AW-1:0]];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_byp     <= 8'd0;
            rx_byp_use <= 1'b0;
        end else begin
            rx_byp     <= rx_data;
            rx_byp_use <= rx_push && (rx_wptr[RX_AW-1:0] == rx_rptr[RX_AW-1:0]);
        end
    end
    wire [7:0] rx_head = rx_byp_use ? rx_byp : rx_ram_q;

    // ---------------------------------------------------------
    // 読み出しの値
    // ---------------------------------------------------------
    always @(*) begin
        prdata = 32'd0;
        if (reg_sel == REG_DATA && !rx_empty) begin
            prdata = {24'd0, rx_head};
        end
        if (reg_sel == REG_STATUS) begin
            prdata = {27'd0, rx_frame, rx_overrun, !rx_empty, (hold_valid || tx_busy), !hold_valid};
        end
        if (reg_sel == REG_CTRL) begin
            prdata = {31'd0, ctrl_hold};
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{pwdata[31:8], pstrb[3:1], paddr[31:4], paddr[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
