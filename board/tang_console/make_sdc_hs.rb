# 166.7 MHz 版のタイミング制約を、top.sdc から作る (build.sh が SDRAM=hs のときに呼ぶ)。
#   ruby make_sdc_hs.rb <top.sdc> <出力先>
#
# 20 MHz 版の SDRAM のクロック (clk20) の制約を外し、2 つ目の PLL の s_clk の制約を追加する。
# 読み出しデータを取り込むタイミングは IODELAY と取り込むエッジで決める (sdram_io.v) ので、クロックは s_clk の 1 本

src, dst = ARGV
abort 'usage: ruby make_sdc_hs.rb <top.sdc> <out>' unless dst

s = File.read(src)
line20 = s[/^create_generated_clock -name sdram_clk .*\n/] or abort 'top.sdc has no sdram_clk constraint'
s.sub!(line20, "// SDRAM の制御の 166.7 MHz 版 (= board/tang_console/sdram_pll.v。VCO 1000 MHz = 50 MHz × 20、÷ 6)\n" \
               "create_generated_clock -name s_clk -source [get_ports {clk50}] -multiply_by 10 -divide_by 3 [get_nets {s_clk}]\n")
s.sub!('-group [get_clocks {sdram_clk}]', '-group [get_clocks {s_clk}]') or abort 'the clock groups in top.sdc do not include sdram_clk'
File.write(dst, s)
