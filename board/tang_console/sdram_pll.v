// =============================================================
// File:        board/tang_console/sdram_pll.v
// Module:      sdram_pll
// Role:        166.7 MHz 版の SDRAM コントローラのクロックを生成する、2 つ目の PLL。AE350 の PLL (ae350_pll.v、
//              PLL_R[0]、VCO 800 MHz) とは別に置く (800 MHz の VCO からは 166.7 MHz を生成できないため)。
//              パラメータの並びは ae350_pll.v と同じ。
//
//     VCO   = 50 MHz ÷ IDIV (1) × FBDIV (1) × MDIV (20) = 1000 MHz   (DS981-1.1.3E の Table 3-42 の範囲 650〜1300 MHz に収まる。PFD 50 MHz も 19〜81.25 MHz に収まる)
//     s_clk = VCO ÷ ODIV0 (6) = 166.7 MHz   コントローラのクロック (W9825G6KH-6 の CL 3 の最小周期 6 ns)
//
//     読み出しデータを取り込むタイミングは、PLL の位相ではなく、sdram_io の IODELAY と取り込むエッジで決める (1 本のピンの
//     ODDR と IDDR は同じクロックで動かす必要があるため。合成の CK0012)
// =============================================================
`default_nettype none

module sdram_pll (
    input  wire clkin,      // 50 MHz
    input  wire reset,      // 1 の間、PLL をリセット状態に保つ
    output wire s_clk,
    output wire lock
);
    wire clkout1, clkout2, clkout3, clkout4, clkout5, clkout6, clkfbout;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{clkout1, clkout2, clkout3, clkout4, clkout5, clkout6, clkfbout};   // 使うのは CLKOUT0 (s_clk) だけ
    /* verilator lint_on UNUSEDSIGNAL */

    PLL #(
        .FCLKIN            ("50"),
        .IDIV_SEL          (1),
        .FBDIV_SEL         (1),
        .MDIV_SEL          (20),
        .MDIV_FRAC_SEL     (0),
        .ODIV0_SEL         (6),
        .ODIV0_FRAC_SEL    (0),
        .ODIV1_SEL         (6),
        .ODIV2_SEL         (8),
        .ODIV3_SEL         (8),
        .ODIV4_SEL         (8),
        .ODIV5_SEL         (8),
        .ODIV6_SEL         (8),
        .CLKOUT0_EN        ("TRUE"),
        .CLKOUT1_EN        ("FALSE"),
        .CLKOUT2_EN        ("FALSE"),
        .CLKOUT3_EN        ("FALSE"),
        .CLKOUT4_EN        ("FALSE"),
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
        .CLKOUT0(s_clk), .CLKOUT1(clkout1), .CLKOUT2(clkout2), .CLKOUT3(clkout3),
        .CLKOUT4(clkout4), .CLKOUT5(clkout5), .CLKOUT6(clkout6), .CLKFBOUT(clkfbout),
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
