// =============================================================
// File:        board/tang_console/ae350_pll.v
// Module:      ae350_pll
// Role:        Tang Console の 50 MHz の発振器から、AE350 のクロック 5 本を生成する PLL。
//              分周比は Sipeed の AE350 のデモの PLL (gowin_pll_ae350.v) と同じ。
//
//     VCO       = 50 MHz ÷ IDIV (1) × FBDIV (1) × MDIV (16) = 800 MHz
//     DDR_CLK   = VCO ÷ ODIV0 (16) = 50 MHz
//     CORE_CLK  = VCO ÷ ODIV1 (CORE_DIV、既定値 1) = 800 MHz
//     AHB_CLK   = VCO ÷ ODIV2 (AHB_DIV、既定値 8)  = 100 MHz
//     APB_CLK   = VCO ÷ ODIV3 (8)  = 100 MHz
//     RTC_CLK   = VCO ÷ ODIV4 (80) = 10 MHz
//     (CLKOUT5 は使わない。SDRAM コントローラのクロックは、2 つ目の PLL (sdram_pll.v) が作る)
//
// Parameters:
//   CORE_DIV / AHB_DIV  CORE_CLK と AHB_CLK の分周比 (既定値は本物の AE350 の 800 MHz と 100 MHz。Hazard3 版をファブリック上で
//                       動かすビルド (build.sh の CPU=hazard3) では、配置配線の Fmax に合わせて下げる)
// =============================================================
`default_nettype none

module ae350_pll #(
    parameter integer CORE_DIV = 1,
    parameter integer AHB_DIV  = 8
) (
    input  wire clkin,      // 50 MHz
    input  wire reset,      // 1 の間、PLL をリセット状態に保つ
    output wire core_clk,
    output wire ddr_clk,
    output wire ahb_clk,
    output wire apb_clk,
    output wire rtc_clk,
    output wire lock        // 周波数が安定すると 1
);
    wire clkout5, clkout6, clkfbout;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{clkout5, clkout6, clkfbout};   // CLKOUT5 と CLKOUT6 は使わず、帰還は内部 (CLKFB_SEL INTERNAL)
    /* verilator lint_on UNUSEDSIGNAL */

    PLL #(
        .FCLKIN            ("50"),
        .IDIV_SEL          (1),
        .FBDIV_SEL         (1),
        .MDIV_SEL          (16),
        .MDIV_FRAC_SEL     (0),
        .ODIV0_SEL         (16),
        .ODIV0_FRAC_SEL    (0),
        .ODIV1_SEL         (CORE_DIV),
        .ODIV2_SEL         (AHB_DIV),
        .ODIV3_SEL         (8),
        .ODIV4_SEL         (80),
        .ODIV5_SEL         (40),
        .ODIV6_SEL         (8),
        .CLKOUT0_EN        ("TRUE"),
        .CLKOUT1_EN        ("TRUE"),
        .CLKOUT2_EN        ("TRUE"),
        .CLKOUT3_EN        ("TRUE"),
        .CLKOUT4_EN        ("TRUE"),
        .CLKOUT5_EN        ("FALSE"),
        .CLKOUT6_EN        ("FALSE"),
        .CLKFB_SEL         ("INTERNAL"),
        .CLKOUT0_DT_DIR    (1'b1),
        .CLKOUT1_DT_DIR    (1'b1),
        .CLKOUT2_DT_DIR    (1'b1),
        .CLKOUT3_DT_DIR    (1'b1),
        .CLKOUT0_DT_STEP   (0),
        .CLKOUT1_DT_STEP   (0),
        .CLKOUT2_DT_STEP   (0),
        .CLKOUT3_DT_STEP   (0),
        .CLK0_IN_SEL       (1'b0),
        .CLK0_OUT_SEL      (1'b0),
        .CLK1_IN_SEL       (1'b0),
        .CLK1_OUT_SEL      (1'b0),
        .CLK2_IN_SEL       (1'b0),
        .CLK2_OUT_SEL      (1'b0),
        .CLK3_IN_SEL       (1'b0),
        .CLK3_OUT_SEL      (1'b0),
        .CLK4_IN_SEL       (2'b00),
        .CLK4_OUT_SEL      (1'b0),
        .CLK5_IN_SEL       (1'b0),
        .CLK5_OUT_SEL      (1'b0),
        .CLK6_IN_SEL       (1'b0),
        .CLK6_OUT_SEL      (1'b0),
        .DYN_DPA_EN        ("FALSE"),
        .CLKOUT0_PE_COARSE (0),
        .CLKOUT0_PE_FINE   (0),
        .CLKOUT1_PE_COARSE (0),
        .CLKOUT1_PE_FINE   (0),
        .CLKOUT2_PE_COARSE (0),
        .CLKOUT2_PE_FINE   (0),
        .CLKOUT3_PE_COARSE (0),
        .CLKOUT3_PE_FINE   (0),
        .CLKOUT4_PE_COARSE (0),
        .CLKOUT4_PE_FINE   (0),
        .CLKOUT5_PE_COARSE (0),
        .CLKOUT5_PE_FINE   (0),
        .CLKOUT6_PE_COARSE (0),
        .CLKOUT6_PE_FINE   (0),
        .DYN_PE0_SEL       ("FALSE"),
        .DYN_PE1_SEL       ("FALSE"),
        .DYN_PE2_SEL       ("FALSE"),
        .DYN_PE3_SEL       ("FALSE"),
        .DYN_PE4_SEL       ("FALSE"),
        .DYN_PE5_SEL       ("FALSE"),
        .DYN_PE6_SEL       ("FALSE"),
        .DE0_EN            ("FALSE"),
        .DE1_EN            ("FALSE"),
        .DE2_EN            ("FALSE"),
        .DE3_EN            ("FALSE"),
        .DE4_EN            ("FALSE"),
        .DE5_EN            ("FALSE"),
        .DE6_EN            ("FALSE"),
        .RESET_I_EN        ("FALSE"),
        .RESET_O_EN        ("FALSE"),
        .ICP_SEL           (6'bXXXXXX),
        .LPF_RES           (3'bXXX),
        .LPF_CAP           (2'b00),
        .SSC_EN            ("FALSE"),
        .DYN_IDIV_SEL      ("FALSE"),
        .DYN_FBDIV_SEL     ("FALSE"),
        .DYN_MDIV_SEL      ("FALSE"),
        .DYN_ODIV0_SEL     ("FALSE"),
        .DYN_ODIV1_SEL     ("FALSE"),
        .DYN_ODIV2_SEL     ("FALSE"),
        .DYN_ODIV3_SEL     ("FALSE"),
        .DYN_ODIV4_SEL     ("FALSE"),
        .DYN_ODIV5_SEL     ("FALSE"),
        .DYN_ODIV6_SEL     ("FALSE"),
        .DYN_DT0_SEL       ("FALSE"),
        .DYN_DT1_SEL       ("FALSE"),
        .DYN_DT2_SEL       ("FALSE"),
        .DYN_DT3_SEL       ("FALSE"),
        .DYN_ICP_SEL       ("FALSE"),
        .DYN_LPF_SEL       ("FALSE")
    ) u_pll (
        .LOCK(lock),
        .CLKOUT0(ddr_clk), .CLKOUT1(core_clk), .CLKOUT2(ahb_clk), .CLKOUT3(apb_clk),
        .CLKOUT4(rtc_clk), .CLKOUT5(clkout5), .CLKOUT6(clkout6), .CLKFBOUT(clkfbout),
        .CLKIN(clkin), .CLKFB(1'b0),
        .RESET(reset), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .MDSEL(7'd0), .MDSEL_FRAC(3'd0),
        .ODSEL0(7'd0), .ODSEL0_FRAC(3'd0), .ODSEL1(7'd0), .ODSEL2(7'd0), .ODSEL3(7'd0),
        .ODSEL4(7'd0), .ODSEL5(7'd0), .ODSEL6(7'd0),
        .DT0(4'd0), .DT1(4'd0), .DT2(4'd0), .DT3(4'd0),
        .ICPSEL(6'd0), .LPFRES(3'd0), .LPFCAP(2'd0),
        .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1), .ENCLK3(1'b1),
        .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0)
    );
endmodule

`default_nettype wire
