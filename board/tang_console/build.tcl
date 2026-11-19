# ボード構成を、Tang Console 138K 向けに配置配線してビットストリームを作る。build.sh から gw_sh で実行する。
# チップのリビジョンは B
set here [file dirname [file normalize [info script]]]
set ae   [file normalize $here/../..]
set out  $::env(AE350_BOARD_BUILD)
create_project -name ae350_probe -dir $out -pn GW5AST-LV138PG484AC1/I0 -device_version B -force
set_option -top_module ae350_probe_top
set_option -verilog_std v2001
# HDMI=1 (build.sh) のときは、hdl-util/hdmi (SystemVerilog) を読むので、プロジェクト全体を SystemVerilog 2017 にする
# (Gowin の -verilog_std はプロジェクトに 1 つで、ファイルごとには指定できない)
set hdmi [expr {[info exists ::env(AE350_HDMI)] && $::env(AE350_HDMI) eq "1"}]
if {$hdmi} { set_option -verilog_std sysv2017 }
set_option -print_all_synthesis_warning 1
set_option -gen_text_timing_rpt 1
# 配置配線のオプション (build.sh の PLACE と ROUTE。空なら Gowin の既定値)
if {[info exists ::env(AE350_PLACE_OPTION)] && $::env(AE350_PLACE_OPTION) ne ""} { set_option -place_option $::env(AE350_PLACE_OPTION) }
if {[info exists ::env(AE350_ROUTE_OPTION)] && $::env(AE350_ROUTE_OPTION) ne ""} { set_option -route_option $::env(AE350_ROUTE_OPTION) }
set_option -include_path "$ae/hazard3/hdl"
add_file $out/defines.v
foreach f {apb_uart uart_reset_seq apb_gpint apb_paddr_probe apb_reg_slice ahb_reg_slice ahb_sram ahb_rom ahb_sdram sdram_ctrl_hs sdram_io} { add_file $ae/rtl/$f.v }
add_file $ae/rtl/sdram_bridge.v
add_file $ae/rtl/vendor/verilog-uart/uart_tx.v
add_file $ae/rtl/vendor/verilog-uart/uart_rx.v
add_file $ae/rtl/reset_gen.v
# シミュレーションと同じ shell_top。AE350_SOC は、既定では Hazard3 版 (rtl/AE350_SOC.v) を読み込まないので、本物のプリミティブになる。
# CPU=hazard3 (build.sh) のときは、Hazard3 版をファブリック上で動かす
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
# HDMI=1 (build.sh) のときは、HDMI の出力回路 (hdl-util/hdmi)、テストパターン、試験音、HDMI の PLL を足す
if {$hdmi} {
    foreach f {hdmi tmds_channel serializer packet_picker packet_assembler audio_clock_regeneration_packet audio_sample_packet
               audio_info_frame auxiliary_video_information_info_frame source_product_description_info_frame} { add_file $ae/rtl/vendor/hdmi/$f.sv }
    add_file $ae/rtl/hdmi_test_pattern.v
    add_file $ae/rtl/hdmi_audio_tone.v
    add_file $here/hdmi_pll.v
    # HDMI の PLL の ICP と LPF を決める PLL_INIT (MEM=ddr3 のときは下で足す)
    if {!([info exists ::env(AE350_MEM)] && $::env(AE350_MEM) eq "ddr3")} { add_file $here/ddr3/pll_init.v }
    # HDMI のリセットの同期化に使う (Hazard3 版のビルドでは上で足している)
    if {!([info exists ::env(AE350_CPU)] && $::env(AE350_CPU) eq "hazard3")} { add_file $ae/rtl/ae350_reset_sync.v }
}
# MEM=ddr3 (build.sh) のときは、DDR_H* の先を DDR3 にする (ahb_ddr3、Gowin の DDR3 IP、DDR3 の PLL)
if {[info exists ::env(AE350_MEM)] && $::env(AE350_MEM) eq "ddr3"} {
    add_file $ae/rtl/ahb_ddr3.v
    foreach f {ddr3_memory_interface gowin_pll pll_init} { add_file $here/ddr3/$f.v }
    add_file $out/ddr3_pll/gowin_pll_mod.v
}
# MEM=litedram (build.sh) のときは、DDR_H* の先を LiteDRAM のコントローラにする (ahb_litedram、生成した litedram_core、VexRiscv)
if {[info exists ::env(AE350_MEM)] && $::env(AE350_MEM) eq "litedram"} {
    add_file $ae/rtl/ahb_litedram.v
    add_file $out/litedram_core.v
    add_file $::env(AE350_VEXRISCV_V)
}
# ピン制約と配置制約 (build.sh が出力先に 1 つにまとめて作る。Gowin は制約ファイルを 1 つしか使わないため)
add_file $out/top_build.cst
# タイミング制約 (build.sh が選ぶ。166.7 MHz 版は出力先に生成したものを使う)
add_file $::env(AE350_SDC)
run all
run close
