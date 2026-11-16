# LiteDRAM 版 (build.sh の MEM=litedram) のタイミング制約を、元の制約 (build.sh がそれまでに選んだもの) から作る。
#   ruby make_sdc_litedram.rb <元の制約> <出力先> <DDR3 のクロックの周期 ns> <コントローラのクロックの周期 ns>
#
# litedram_core の内部の 2 つのクロックを追加する: DDR3 のクロック (PLL の出力を DHCE で止められるようにしたもの、sys2x) と、
# それを CLKDIV で分周したコントローラのクロック (sys、user_clk)。どちらも他のクロックとは非同期 (ahb_litedram は DDR_CLK と
# user_clk の間をトグルで乗せ換える)。SDRAM の 20 MHz のクロック (clk20) は使わないので、合成で配線が消える。その制約を外す
# (make_sdc_ddr3.rb と同じ)

src, dst, ddr_ns, sys_ns = ARGV
abort 'usage: ruby make_sdc_litedram.rb <元の指定> <out> <DDR3 のクロックの周期 ns> <制御のクロックの周期 ns>' unless sys_ns

s = File.read(src)
s.sub!(/^create_generated_clock -name sdram_clk .*\n/, '') or abort '元の指定に sdram_clk の指定が無い'
s.sub!(' -group [get_clocks {sdram_clk}]', '') or abort '元の指定のグループに sdram_clk が無い'
s.gsub!(/^report_timing .*\{sdram_clk\}.*\n/, '')
s.sub!(/^(set_clock_groups -asynchronous .*)$/) do
  "#{Regexp.last_match(1)} -group [get_clocks {ld_sys2x}] -group [get_clocks {ld_sys}]"
end or abort '元の指定に set_clock_groups -asynchronous が無い'
s = "// LiteDRAM の版: litedram_core の DDR3 のクロックと、制御のクロック\n" \
    "create_clock -name ld_sys2x -period #{ddr_ns} [get_pins {u_litedram/DHCE/CLKOUT}]\n" \
    "create_clock -name ld_sys -period #{sys_ns} [get_pins {u_litedram/CLKDIV/CLKOUT}]\n" + s
File.write(dst, s)
