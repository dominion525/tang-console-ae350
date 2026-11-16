# 実機の値を読む構成を、Tang Console 138K 向けに配置配線してビットストリームを作る。build.sh から gw_sh で実行する。
# チップの版は B (= 手元のボード。tasks/_shared/tang-console-facts.md)
set here [file dirname [file normalize [info script]]]
set ae   [file normalize $here/../..]
set out  $::env(AE350_BOARD_BUILD)
create_project -name ae350_probe -dir $out -pn GW5AST-LV138PG484AC1/I0 -device_version B -force
set_option -top_module ae350_probe_top
set_option -verilog_std v2001
set_option -print_all_synthesis_warning 1
set_option -gen_text_timing_rpt 1
# 配置配線の設定 (= build.sh の PLACE / ROUTE。空なら Gowin の既定)
if {[info exists ::env(AE350_PLACE_OPTION)] && $::env(AE350_PLACE_OPTION) ne ""} { set_option -place_option $::env(AE350_PLACE_OPTION) }
if {[info exists ::env(AE350_ROUTE_OPTION)] && $::env(AE350_ROUTE_OPTION) ne ""} { set_option -route_option $::env(AE350_ROUTE_OPTION) }
set_option -include_path "$ae/hazard3/hdl"
add_file $out/defines.v
foreach f {apb_uart uart_reset_seq apb_gpint apb_paddr_probe apb_reg_slice ahb_reg_slice ahb_sram ahb_rom ahb_sdram sdram_ctrl_hs sdram_io} { add_file $ae/rtl/$f.v }
add_file $ae/rtl/sdram_bridge.v
add_file $ae/rtl/vendor/verilog-uart/uart_tx.v
add_file $ae/rtl/vendor/verilog-uart/uart_rx.v
add_file $ae/rtl/reset_gen.v
# シミュレーションと同じ shell_top。AE350_SOC は、既定ではモック (= ae350/rtl/AE350_SOC.v) を読まないので、本物の部品になる。
# CPU=hazard3 (= build.sh) のときは、モックと Hazard3 を FPGA のロジックで動かす
add_file $ae/tb/shell_top.v
if {[info exists ::env(AE350_CPU)] && $::env(AE350_CPU) eq "hazard3"} {
    foreach f {AE350_SOC ae350_fabric ae350_reset_sync ae350_plic ae350_plmt} { add_file $ae/rtl/$f.v }
    foreach f {hazard3_cpu_1port hazard3_core hazard3_csr hazard3_decode hazard3_frontend hazard3_instr_decompress
               hazard3_irq_ctrl hazard3_pmp hazard3_power_ctrl hazard3_regfile_1w2r hazard3_triggers
               arith/hazard3_alu arith/hazard3_branchcmp arith/hazard3_mul_fast arith/hazard3_muldiv_seq
               arith/hazard3_onehot_encode arith/hazard3_onehot_priority arith/hazard3_onehot_priority_dynamic
               arith/hazard3_priority_encode arith/hazard3_shift_barrel} { add_file $ae/hazard3/hdl/$f.v }
}
add_file $here/ae350_pll.v
add_file $here/sdram_pll.v
add_file $here/ae350_observer.v
add_file $here/top.v
# MEM=ddr3 (= build.sh) のときは、DDR_H* の先を DDR3 にする (= ahb_ddr3、Gowin の DDR3 の IP、DDR3 の PLL)
if {[info exists ::env(AE350_MEM)] && $::env(AE350_MEM) eq "ddr3"} {
    add_file $ae/rtl/ahb_ddr3.v
    foreach f {ddr3_memory_interface gowin_pll pll_init} { add_file $here/ddr3/$f.v }
    add_file $out/ddr3_pll/gowin_pll_mod.v
}
# MEM=litedram (= build.sh。実験) のときは、DDR_H* の先を LiteDRAM の制御にする (= ahb_litedram、書き出した litedram_core、VexRiscv)
if {[info exists ::env(AE350_MEM)] && $::env(AE350_MEM) eq "litedram"} {
    add_file $ae/rtl/ahb_litedram.v
    add_file $out/litedram_core.v
    add_file $::env(AE350_VEXRISCV_V)
}
# ピンと配置の制約 (= build.sh が出力先に 1 つにまとめて作る。Gowin は制約のファイルを 1 つしか使わない)
add_file $out/top_build.cst
# クロックの指定 (= build.sh が選ぶ。166.7 MHz 版は出力先に作ったもの)
add_file $::env(AE350_SDC)
run all
run close
