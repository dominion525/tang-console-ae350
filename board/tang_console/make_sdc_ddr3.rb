# DDR3 の版 (= build.sh の MEM=ddr3) のクロックの指定を、元の指定 (= build.sh がそれまでに選んだもの) から作る (= 2026-11-13)。
#   ruby make_sdc_ddr3.rb <元の指定> <書き出す先>
#
# DDR3 のメモリのクロック (= 400 MHz、DDR3 の PLL の clkout2) と、DDR3 の IP の利用者の側のクロック (= 100 MHz、IP の中の分周器の
# 出力) を足す。指定の仕方は、実機で動いた Sipeed の DDR3 の試験 (= ddr3_1v4_hs.sdc) と同じ。どちらもほかのクロックとは非同期
# (= ahb_ddr3 は DDR_CLK と IP のクロックの間をトグルで乗せ換える。試験の指定も 400 MHz と分周したクロックの間を外している)

src, dst = ARGV
abort 'usage: ruby make_sdc_ddr3.rb <元の指定> <out>' unless dst

s = File.read(src)
# SDRAM の 20 MHz のクロック (= clk20) は、DDR3 の版では使わないので、合成で線が消える。その指定と、非同期のグループの
# sdram_clk を外す (= make_sdc_hazard3.rb が rtc_clk を外すのと同じ)
s.sub!(/^create_generated_clock -name sdram_clk .*\n/, '') or abort '元の指定に sdram_clk の指定が無い'
s.sub!(' -group [get_clocks {sdram_clk}]', '') or abort '元の指定のグループに sdram_clk が無い'
# Hazard3 の版 (= make_sdc_hazard3.rb) が足す、sdram_clk の遅い経路を報告に出す行も外す (= 2026-11-15)
s.gsub!(/^report_timing .*\{sdram_clk\}.*\n/, '')
s.sub!(/^(set_clock_groups -asynchronous .*)$/) do
  "#{Regexp.last_match(1)} -group [get_clocks {ddr3_mem}] -group [get_clocks {ddr3_sys}]"
end or
  abort '元の指定に set_clock_groups -asynchronous が無い'
s = <<~SDC + s
  // DDR3 の版: DDR3 のメモリのクロックと、DDR3 の IP の利用者の側のクロック
  create_clock -name ddr3_mem -period 2.5 -waveform {0 1.25} [get_nets {ddr3_memory_clk}]
  create_clock -name ddr3_sys -period 10 -waveform {0 5} [get_pins {u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
SDC
File.write(dst, s)
