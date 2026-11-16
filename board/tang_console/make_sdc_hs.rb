# 166.7 MHz 版のクロックの指定を、top.sdc から作る (= build.sh が SDRAM=hs のときに呼ぶ)。
#   ruby make_sdc_hs.rb <top.sdc> <書き出す先>
#
# 20 MHz 版の SDRAM のクロック (= clk20) の指定を外し、2 つ目の PLL の s_clk の指定を足す。
# 読んだデータを取る位置は IODELAY と取る縁で決めるので (= sdram_io.v)、クロックは s_clk 1 本

src, dst = ARGV
abort 'usage: ruby make_sdc_hs.rb <top.sdc> <out>' unless dst

s = File.read(src)
line20 = s[/^create_generated_clock -name sdram_clk .*\n/] or abort 'top.sdc に sdram_clk の指定が無い'
s.sub!(line20, "// SDRAM の制御の 166.7 MHz 版 (= board/tang_console/sdram_pll.v。VCO 1000 MHz = 50 MHz × 20、÷ 6)\n" \
               "create_generated_clock -name s_clk -source [get_ports {clk50}] -multiply_by 10 -divide_by 3 [get_nets {s_clk}]\n")
s.sub!('-group [get_clocks {sdram_clk}]', '-group [get_clocks {s_clk}]') or abort 'top.sdc のグループに sdram_clk が無い'
File.write(dst, s)
