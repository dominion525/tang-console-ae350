// =============================================================
// File:        board/tang_console/hdmi_pll.v
// Module:      hdmi_pll
// Role:        HDMI の出力 (1280×720 / 60 Hz) の画素クロック 74.25 MHz と、その 5 倍の 371.25 MHz (OSER10 の FCLK) を、
//              50 MHz の発振器から作る PLL。PLL を 2 段つなぎ、分数の分周は使わない (Tang Console 138K で HDMI を出している
//              nand2mario/gbatang と同じ構成)。設定は、配置配線のツールが示す範囲 (VCO 650〜1300 MHz の PA1019、
//              PFD = 入力 ÷ IDIV が 19〜81.25 MHz の PA2078) に収まるように決めた。gbatang の設定 (中間 27 MHz、VCO 1350 MHz と
//              1485 MHz) は VCO が範囲を超え、中間 27 MHz のままでは、分数を使わずに両方の範囲に収める設定がない。
//              パラメータの並びは ae350_pll.v と同じ。
//
//     1 段目  PFD = 50 MHz ÷ IDIV (2) = 25 MHz、VCO = PFD × FBDIV (1) × MDIV (27) = 675 MHz
//             clk_mid      = VCO ÷ ODIV0 (10) = 67.5 MHz
//     2 段目  PFD = 67.5 MHz ÷ IDIV (1) = 67.5 MHz、VCO = PFD × FBDIV (1) × MDIV (11) = 742.5 MHz
//             clk_pixel_x5 = VCO ÷ ODIV0 (2)  = 371.25 MHz
//             clk_pixel    = VCO ÷ ODIV1 (10) = 74.25 MHz
//
//     ICP と LPF は、2 段とも PLL_INIT で決める (Gowin のツールが作る PLL と同じ形。リポジトリの DDR3 用の PLL も同じ)。
//     ICP と LPF を与えない形 (ae350_pll.v、sdram_pll.v と同じ) では、2 段目 (PFD 67.5 MHz、倍率 11) がロックしなかった
//     (実機で 2 段目のロックが 0 のまま、画素クロックが 61〜63 MHz でふらついた。PLL_INIT を付けるとロックし、74.25 MHz ちょうどになった)。
//     2 段目は、1 段目がロックするまでリセットしておく。lock は 2 段目のロック (1 段目がロックしていないと 2 段目もロックしない)
// =============================================================
`default_nettype none

module hdmi_pll (
    input  wire clkin,         // 50 MHz
    input  wire reset,         // 1 の間、PLL をリセット状態に保つ
    output wire clk_pixel,     // 74.25 MHz
    output wire clk_pixel_x5,  // 371.25 MHz
    output wire lock
);
    wire clk_mid, lock_mid;
    wire a_clkout1, a_clkout2, a_clkout3, a_clkout4, a_clkout5, a_clkout6, a_clkfbout;
    wire b_clkout2, b_clkout3, b_clkout4, b_clkout5, b_clkout6, b_clkfbout;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{a_clkout1, a_clkout2, a_clkout3, a_clkout4, a_clkout5, a_clkout6, a_clkfbout,
                    b_clkout2, b_clkout3, b_clkout4, b_clkout5, b_clkout6, b_clkfbout};
    /* verilator lint_on UNUSEDSIGNAL */

    // ICP (チャージポンプの電流) と LPF (ループフィルタの抵抗) は、Gowin のツールが作る PLL と同じく、PLL_INIT (ddr3/pll_init.v) が
    // 倍率 (MULTI_FAC = VCO ÷ PFD) に応じた候補を順に試して決める。PLL_INIT は PLL のリセットも出し、決め終えてからロックを返す
    wire raw_lock_mid, raw_lock, rst_mid, rst_hdmi;
    wire [5:0] icp_mid, icp_hdmi;
    wire [2:0] lpf_mid, lpf_hdmi;
    PLL_INIT #(.CLK_PERIOD (20), .MULTI_FAC (27)) u_init_mid (
        .CLKIN (clkin), .I_RST (reset), .PLLLOCK (raw_lock_mid), .O_RST (rst_mid),
        .ICPSEL (icp_mid), .LPFRES (lpf_mid), .O_LOCK (lock_mid)
    );
    // 2 段目の PLL_INIT は、1 段目がロックするまでリセットしておく (初期化のクロックは、どちらも 50 MHz の clkin)
    PLL_INIT #(.CLK_PERIOD (20), .MULTI_FAC (11)) u_init_hdmi (
        .CLKIN (clkin), .I_RST (reset | ~lock_mid), .PLLLOCK (raw_lock), .O_RST (rst_hdmi),
        .ICPSEL (icp_hdmi), .LPFRES (lpf_hdmi), .O_LOCK (lock)
    );

    // 1 段目: 50 MHz → 67.5 MHz
    PLL #(
        .FCLKIN            ("50"),
        .IDIV_SEL          (2),
        .FBDIV_SEL         (1),
        .MDIV_SEL          (27),
        .MDIV_FRAC_SEL     (0),
        .ODIV0_SEL         (10),
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
        .DYN_ICP_SEL       ("TRUE"),
        .DYN_LPF_SEL       ("TRUE")
    ) u_pll_mid (
        .LOCK(raw_lock_mid),
        .CLKOUT0(clk_mid), .CLKOUT1(a_clkout1), .CLKOUT2(a_clkout2), .CLKOUT3(a_clkout3),
        .CLKOUT4(a_clkout4), .CLKOUT5(a_clkout5), .CLKOUT6(a_clkout6), .CLKFBOUT(a_clkfbout),
        .CLKIN(clkin), .CLKFB(1'b0),
        .RESET(rst_mid), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .MDSEL(7'd0), .MDSEL_FRAC(3'd0),
        .ODSEL0(7'd0), .ODSEL0_FRAC(3'd0), .ODSEL1(7'd0), .ODSEL2(7'd0), .ODSEL3(7'd0),
        .ODSEL4(7'd0), .ODSEL5(7'd0), .ODSEL6(7'd0),
        .DT0(4'd0), .DT1(4'd0), .DT2(4'd0), .DT3(4'd0),
        .ICPSEL(icp_mid), .LPFRES(lpf_mid), .LPFCAP(2'd0),
        .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1), .ENCLK3(1'b1),
        .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0)
    );

    // 2 段目: 67.5 MHz → 371.25 MHz と 74.25 MHz
    PLL #(
        .FCLKIN            ("67.5"),
        .IDIV_SEL          (1),
        .FBDIV_SEL         (1),
        .MDIV_SEL          (11),
        .MDIV_FRAC_SEL     (0),
        .ODIV0_SEL         (2),
        .ODIV0_FRAC_SEL    (0),
        .ODIV1_SEL         (10),
        .ODIV2_SEL         (8),
        .ODIV3_SEL         (8),
        .ODIV4_SEL         (8),
        .ODIV5_SEL         (8),
        .ODIV6_SEL         (8),
        .CLKOUT0_EN        ("TRUE"),
        .CLKOUT1_EN        ("TRUE"),
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
        .DYN_ICP_SEL       ("TRUE"),
        .DYN_LPF_SEL       ("TRUE")
    ) u_pll_hdmi (
        .LOCK(raw_lock),
        .CLKOUT0(clk_pixel_x5), .CLKOUT1(clk_pixel), .CLKOUT2(b_clkout2), .CLKOUT3(b_clkout3),
        .CLKOUT4(b_clkout4), .CLKOUT5(b_clkout5), .CLKOUT6(b_clkout6), .CLKFBOUT(b_clkfbout),
        .CLKIN(clk_mid), .CLKFB(1'b0),
        .RESET(rst_hdmi), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .MDSEL(7'd0), .MDSEL_FRAC(3'd0),
        .ODSEL0(7'd0), .ODSEL0_FRAC(3'd0), .ODSEL1(7'd0), .ODSEL2(7'd0), .ODSEL3(7'd0),
        .ODSEL4(7'd0), .ODSEL5(7'd0), .ODSEL6(7'd0),
        .DT0(4'd0), .DT1(4'd0), .DT2(4'd0), .DT3(4'd0),
        .ICPSEL(icp_hdmi), .LPFRES(lpf_hdmi), .LPFCAP(2'd0),
        .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1), .ENCLK3(1'b1),
        .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0)
    );
endmodule

`default_nettype wire
