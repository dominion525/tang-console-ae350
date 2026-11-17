// ボード構成 (board/tang_console/top.v) のタイミング制約。
create_clock -name clk50 -period 20 [get_ports {clk50}]

// PLL の出力 (board/tang_console/ae350_pll.v)。周波数は Sipeed のデモと同じ
create_generated_clock -name ddr_clk -source [get_ports {clk50}] -multiply_by 1 -divide_by 1 [get_nets {ddr_clk}]
create_generated_clock -name core_clk -source [get_ports {clk50}] -multiply_by 16 -divide_by 1 [get_nets {core_clk}]
create_generated_clock -name ahb_clk -source [get_ports {clk50}] -multiply_by 2 -divide_by 1 [get_nets {ahb_clk}]
create_generated_clock -name apb_clk -source [get_ports {clk50}] -multiply_by 2 -divide_by 1 [get_nets {apb_clk}]
create_generated_clock -name rtc_clk -source [get_ports {clk50}] -multiply_by 1 -divide_by 5 [get_nets {rtc_clk}]
// SDRAM コントローラのクロック (20 MHz)
create_generated_clock -name sdram_clk -source [get_ports {clk50}] -multiply_by 2 -divide_by 5 [get_nets {clk20}]

// AE350 は内部でクロックごとに乗せ換える。FPGA 側の回路も、クロックをまたぐ経路は AE350 を通る (ROM と EXTS の RAM は
// AHB_CLK、UART と APB のレジスタは APB_CLK)。リセットは 50 MHz で作り、受け側で同期化する
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {core_clk}] -group [get_clocks {ddr_clk}] -group [get_clocks {ahb_clk}] -group [get_clocks {apb_clk}] -group [get_clocks {rtc_clk}] -group [get_clocks {sdram_clk}]
