// =============================================================
// File:        board/tang_console/ae350_observer.v
// Module:      ae350_observer
// Role:        実機で AE350 が動いているかを、CPU を通さずに調べる監視回路。
//              50 MHz で動き、約 1 秒ごとに UART へ 1 行出力する。
//
//   OBS lk=<PLL のロック> rs=<リセット解除> hr=<HRESETN> pr=<PRESETN>
//       rom=<ROM_H* の読み出し回数> ra=<最後の ROM_HADDR> apb=<APB_P* の転送回数> pa=<最後の PADDR>
//       tx=<CPU が UART に出力した文字数> c=<最後の文字> m=<{DDR_RSTN, CORE0_WFI_MODE, RTC_WAKEUP, PRDYN_CHAIN_O}>
//
//   - 回数とアドレスは、それぞれのクロック (AHB_CLK、APB_CLK) で数え、50 MHz へ 1 ビットずつ 2 段の FF で移す
//     (変化の途中の値を読むことがある。動いているか、どこでループしているかを調べるためのもの)
//   - CPU の出力文字は、ファブリック側の UART (apb_uart) の送信線を 50 MHz で受信し直して数える
//   - リセットは持たない (リセットが解除されたかも監視するため)。レジスタは initial の値 (FPGA のコンフィグレーション時の値) から始める
//
// Ports:
//   input  wire        clk50 / lock / rst_n
//   input  wire        ahb_clk / hresetn / rom_htrans1 / rom_haddr
//   input  wire        apb_clk / presetn / apb_access / apb_paddr
//   input  wire        cpu_txd
//   output wire        txd       この回路の UART の送信 (50 MHz ÷ 8 ÷ PRESCALE。既定値 5 で 1,250,000 bps)
// =============================================================

`default_nettype none

module ae350_observer #(
    parameter [15:0] PRESCALE = 16'd5
) (
    input  wire        clk50,
    input  wire        lock,
    input  wire        rst_n,
    input  wire        ahb_clk,
    input  wire        hresetn,
    input  wire        rom_htrans1,
    input  wire [31:0] rom_haddr,
    input  wire        apb_clk,
    input  wire        presetn,
    input  wire        apb_access,
    input  wire [31:0] apb_paddr,
    input  wire        cpu_txd,
    input  wire [3:0]  misc,      // AE350 のその他の出力 ({DDR_RSTN, CORE0_WFI_MODE, RTC_WAKEUP, PRDYN_CHAIN_O})
    output wire        txd,
    output wire        active     // 1 の間は txd を USB シリアルに出力する (それ以外は CPU の文字を出力する)
);

    // ---- AHB_CLK: ROM_H* の読み出し ----
    reg [31:0] rom_cnt;  initial rom_cnt = 32'd0;
    reg [31:0] rom_last; initial rom_last = 32'd0;
    always @(posedge ahb_clk) begin
        if (rom_htrans1) begin
            rom_cnt  <= rom_cnt + 32'd1;
            rom_last <= rom_haddr;
        end
    end

    // ---- APB_CLK: APB_P* の転送 ----
    // AE350 の出力は 1 段のレジスタで受けてから使う (AE350 からの配線が長いので、CE に直接配線しない)
    reg        apb_access_q; initial apb_access_q = 1'b0;
    reg [31:0] apb_paddr_q;  initial apb_paddr_q = 32'd0;
    reg [31:0] apb_cnt;      initial apb_cnt = 32'd0;
    reg [31:0] apb_last;     initial apb_last = 32'd0;
    always @(posedge apb_clk) begin
        apb_access_q <= apb_access;
        apb_paddr_q  <= apb_paddr;
        if (apb_access_q) begin
            apb_cnt  <= apb_cnt + 32'd1;
            apb_last <= apb_paddr_q;
        end
    end

    // ---- 50 MHz へ移す ----
    reg [135:0] s1; initial s1 = 136'd0;
    reg [135:0] s2; initial s2 = 136'd0;
    always @(posedge clk50) begin
        s1 <= {misc, hresetn, presetn, lock, rst_n, rom_cnt, rom_last, apb_cnt, apb_last};
        s2 <= s1;
    end

    // ---- CPU が出力した文字を受信し直す ----
    wire [7:0] rx_data;
    wire       rx_valid;
    /* verilator lint_off PINCONNECTEMPTY */
    uart_rx u_rx (
        .clk           (clk50),
        .rst           (1'b0),
        .m_axis_tdata  (rx_data),
        .m_axis_tvalid (rx_valid),
        .m_axis_tready (1'b1),
        .rxd           (cpu_txd),
        .busy          (),
        .overrun_error (),
        .frame_error   (),
        .prescale      (PRESCALE)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    reg [15:0] tx_cnt;  initial tx_cnt = 16'd0;
    reg [7:0]  tx_last; initial tx_last = 8'd0;
    always @(posedge clk50) begin
        if (rx_valid) begin
            tx_cnt  <= tx_cnt + 16'd1;
            tx_last <= rx_data;
        end
    end

    // ---- 1 行を組み立てて出力する ----
    // 行の形式 (文字の位置と内容)
    //   "OBS lk=L rs=R hr=H pr=P rom=XXXXXXXX ra=XXXXXXXX apb=XXXXXXXX pa=XXXXXXXX tx=XXXX c=XX m=X\r\n"
    localparam integer LEN = 91;
    reg [135:0] snap; initial snap = 136'd0;
    reg [15:0]  snap_tx; initial snap_tx = 16'd0;
    reg [7:0]   snap_c;  initial snap_c = 8'd0;

    function [7:0] hex(input [3:0] v);
        hex = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h57 + {4'd0, v});
    endfunction

    function [7:0] bit01(input b);
        bit01 = b ? "1" : "0";
    endfunction

    reg [7:0] ch;
    reg [6:0] pos; initial pos = 7'd0;
    always @(*) begin
        case (pos)
            7'd0:  ch = "O";  7'd1:  ch = "B";  7'd2:  ch = "S";  7'd3:  ch = " ";
            7'd4:  ch = "l";  7'd5:  ch = "k";  7'd6:  ch = "=";  7'd7:  ch = bit01(snap[129]);
            7'd8:  ch = " ";  7'd9:  ch = "r";  7'd10: ch = "s";  7'd11: ch = "=";  7'd12: ch = bit01(snap[128]);
            7'd13: ch = " ";  7'd14: ch = "h";  7'd15: ch = "r";  7'd16: ch = "=";  7'd17: ch = bit01(snap[131]);
            7'd18: ch = " ";  7'd19: ch = "p";  7'd20: ch = "r";  7'd21: ch = "=";  7'd22: ch = bit01(snap[130]);
            7'd23: ch = " ";  7'd24: ch = "r";  7'd25: ch = "o";  7'd26: ch = "m";  7'd27: ch = "=";
            7'd28: ch = hex(snap[127:124]); 7'd29: ch = hex(snap[123:120]); 7'd30: ch = hex(snap[119:116]); 7'd31: ch = hex(snap[115:112]);
            7'd32: ch = hex(snap[111:108]); 7'd33: ch = hex(snap[107:104]); 7'd34: ch = hex(snap[103:100]); 7'd35: ch = hex(snap[99:96]);
            7'd36: ch = " ";  7'd37: ch = "r";  7'd38: ch = "a";  7'd39: ch = "=";
            7'd40: ch = hex(snap[95:92]); 7'd41: ch = hex(snap[91:88]); 7'd42: ch = hex(snap[87:84]); 7'd43: ch = hex(snap[83:80]);
            7'd44: ch = hex(snap[79:76]); 7'd45: ch = hex(snap[75:72]); 7'd46: ch = hex(snap[71:68]); 7'd47: ch = hex(snap[67:64]);
            7'd48: ch = " ";  7'd49: ch = "a";  7'd50: ch = "p";  7'd51: ch = "b";  7'd52: ch = "=";
            7'd53: ch = hex(snap[63:60]); 7'd54: ch = hex(snap[59:56]); 7'd55: ch = hex(snap[55:52]); 7'd56: ch = hex(snap[51:48]);
            7'd57: ch = hex(snap[47:44]); 7'd58: ch = hex(snap[43:40]); 7'd59: ch = hex(snap[39:36]); 7'd60: ch = hex(snap[35:32]);
            7'd61: ch = " ";  7'd62: ch = "p";  7'd63: ch = "a";  7'd64: ch = "=";
            7'd65: ch = hex(snap[31:28]); 7'd66: ch = hex(snap[27:24]); 7'd67: ch = hex(snap[23:20]); 7'd68: ch = hex(snap[19:16]);
            7'd69: ch = hex(snap[15:12]); 7'd70: ch = hex(snap[11:8]);  7'd71: ch = hex(snap[7:4]);   7'd72: ch = hex(snap[3:0]);
            7'd73: ch = " ";  7'd74: ch = "t";  7'd75: ch = "x";  7'd76: ch = "=";
            7'd77: ch = hex(snap_tx[15:12]); 7'd78: ch = hex(snap_tx[11:8]); 7'd79: ch = hex(snap_tx[7:4]); 7'd80: ch = hex(snap_tx[3:0]);
            7'd81: ch = " ";  7'd82: ch = "c";  7'd83: ch = "=";
            7'd84: ch = hex(snap_c[7:4]); 7'd85: ch = hex(snap_c[3:0]);
            7'd86: ch = " ";  7'd87: ch = "m";  7'd88: ch = "=";  7'd89: ch = hex(snap[135:132]);
            7'd90: ch = 8'h0d;
            default: ch = 8'h0a;
        endcase
    end

    // CPU の送信線が 0.1 秒以上 1 のまま (文字を出力していない) のときだけ、行の出力を始める
    reg  [22:0] idle;    initial idle = 23'd0;
    always @(posedge clk50) begin
        if (!cpu_txd)                  idle <= 23'd0;
        else if (idle != 23'd5_000_000) idle <= idle + 23'd1;
    end
    wire cpu_idle = (idle == 23'd5_000_000);

    reg  [25:0] tick;    initial tick = 26'd0;
    reg         sending; initial sending = 1'b0;
    wire        tready;

    always @(posedge clk50) begin
        if (!sending) begin
            if (tick >= 26'd49_999_999 && cpu_idle) begin
                tick    <= 26'd0;
                snap    <= s2;
                snap_tx <= tx_cnt;
                snap_c  <= tx_last;
                pos     <= 7'd0;
                sending <= 1'b1;
            end else if (tick != 26'd49_999_999) begin
                tick <= tick + 26'd1;
            end
        end else if (tready) begin
            if (pos == LEN[6:0]) sending <= 1'b0;
            else                 pos <= pos + 7'd1;
        end
    end

    wire tx_busy;

    uart_tx u_tx (
        .clk           (clk50),
        .rst           (1'b0),
        .s_axis_tdata  (ch),
        .s_axis_tvalid (sending),
        .s_axis_tready (tready),
        .txd           (txd),
        .busy          (tx_busy),
        .prescale      (PRESCALE)
    );

    assign active = sending || tx_busy;

endmodule

`default_nettype wire
