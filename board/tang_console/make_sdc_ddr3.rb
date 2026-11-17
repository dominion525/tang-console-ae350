# DDR3 版 (build.sh の MEM=ddr3) のタイミング制約を、元の制約 (build.sh がそれまでに選んだもの) から作る。
#   ruby make_sdc_ddr3.rb <元の制約> <出力先>
#
# DDR3 のメモリクロック (400 MHz、DDR3 の PLL の clkout2) と、DDR3 IP のユーザー側のクロック (100 MHz、IP 内部の分周器の
# 出力) を追加する。制約の書き方は、実機で動作した Sipeed の DDR3 のテスト (ddr3_1v4_hs.sdc) と同じ。どちらも他のクロックとは非同期
# (ahb_ddr3 は DDR_CLK と IP のクロックの間をトグルで乗せ換える。テストの制約も、400 MHz と分周したクロックの間を除外している)

src, dst = ARGV
abort 'usage: ruby make_sdc_ddr3.rb <input sdc> <output sdc>' unless dst

s = File.read(src)
# SDRAM の 20 MHz のクロック (clk20) は DDR3 版では使わないので、合成で配線が消える。その制約と、非同期グループの
# sdram_clk を外す (make_sdc_hazard3.rb が rtc_clk を外すのと同じ)
s.sub!(/^create_generated_clock -name sdram_clk .*\n/, '') or abort 'the input sdc has no sdram_clk constraint'
s.sub!(' -group [get_clocks {sdram_clk}]', '') or abort 'the clock groups in the input sdc do not include sdram_clk'
# Hazard3 版 (make_sdc_hazard3.rb) が追加する、sdram_clk のクリティカルパスをレポートに出す行も外す
s.gsub!(/^report_timing .*\{sdram_clk\}.*\n/, '')
s.sub!(/^(set_clock_groups -asynchronous .*)$/) do
  "#{Regexp.last_match(1)} -group [get_clocks {ddr3_mem}] -group [get_clocks {ddr3_sys}]"
end or
  abort 'the input sdc has no set_clock_groups -asynchronous'
s = <<~SDC + s
  // DDR3 build: DDR3 memory clock and DDR3 IP user-side clock
  create_clock -name ddr3_mem -period 2.5 -waveform {0 1.25} [get_nets {ddr3_memory_clk}]
  create_clock -name ddr3_sys -period 10 -waveform {0 5} [get_pins {u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
SDC
File.write(dst, s)
