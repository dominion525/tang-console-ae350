// ボード構成 (board/tang_console/top.v) のタイミング制約。
create_clock -name clk50 -period 20 [get_ports {clk50}]

// PLL の出力 (board/tang_console/ae350_pll.v)。周波数は Sipeed のデモと同じ
create_generated_clock -name ddr_clk -source [get_ports {clk50}] -multiply_by 1 -divide_by 1 [get_nets {ddr_clk}]
create_generated_clock -name core_clk -source [get_ports {clk50}] -multiply_by 16 -divide_by 1 [get_nets {core_clk}]
create_generated_clock -name ahb_clk -source [get_ports {clk50}] -multiply_by 2 -divide_by 1 [get_nets {ahb_clk}]
create_generated_clock -name apb_clk -source [get_ports {clk50}] -multiply_by 2 -divide_by 1 [get_nets {apb_clk}]
create_generated_clock -name rtc_clk -source [get_ports {clk50}] -multiply_by 1 -divide_by 5 [get_nets {rtc_clk}]
// SDRAM コントローラのクロック (board/tang_console/sdram_pll.v: VCO 1000 MHz = 50 MHz × 20、÷ 6 = 166.7 MHz)。
// DDR_H* の先が DDR3 の構成では、この PLL を置かないので、make_sdc_ddr3.rb と make_sdc_litedram.rb が外す
create_generated_clock -name s_clk -source [get_ports {clk50}] -multiply_by 10 -divide_by 3 [get_nets {s_clk}]

// AE350 は内部でクロックごとに乗せ換える。FPGA 側の回路も、クロックをまたぐ経路は AE350 を通る (ROM と EXTS の RAM は
// AHB_CLK、UART と APB のレジスタは APB_CLK)。ただし、ブリッジ回路 (rtl/ahb_sdram.v。DDR_CLK と s_clk の間の非同期の FIFO) と、
// フレームバッファの表示の回路 (rtl/fb_display.v) は、FPGA 側で乗せ換える。リセットは 50 MHz で作り、受け側で同期化する
// 非同期の FIFO (rtl/ahb_sdram.v の書き込みのバッファ) のグレイコードのポインタは、ビットの間の配線のずれを制約しない。
// ポインタは 1 回に 1 ビットしか変わらないので、ずれが受け側のクロックの 1 周期 (s_clk 6 ns、ddr_clk 10 ns) より十分小さければ、
// 受け側は前の値か次の値のどちらかを受ける。一般には set_max_delay -datapath_only で上限を付けるが、Gowin の set_max_delay には
// -datapath_only がなく、同じ経路では set_clock_groups が set_max_delay より優先される (Gowin SUG940-2.0E の 3.8 と 5.4.2) ため、付けない
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {core_clk}] -group [get_clocks {ddr_clk}] -group [get_clocks {ahb_clk}] -group [get_clocks {apb_clk}] -group [get_clocks {rtc_clk}] -group [get_clocks {s_clk}]
