# Hazard3 版 (build.sh の CPU=hazard3) のタイミング制約を、元の制約 (top.sdc) から作る。
#   ruby make_sdc_hazard3.rb <元の制約> <出力先>
#
# Hazard3 版 (rtl/AE350_SOC.v) は RTC_CLK を使わない (PLMT は AHB_CLK で進む) ので、合成で rtc_clk の配線が消える。
# rtc_clk の制約と、非同期グループの rtc_clk を外す。CORE_CLK と AHB_CLK は、Hazard3 版の 40 MHz と 50 MHz にする
# (top.v の AE350_CPU_HAZARD3)

src, dst = ARGV
abort 'usage: ruby make_sdc_hazard3.rb <input sdc> <output sdc>' unless dst

s = File.read(src)
s.sub!(/^create_generated_clock -name rtc_clk .*\n/, '') or abort 'the input sdc has no rtc_clk constraint'
s.sub!(' -group [get_clocks {rtc_clk}]', '') or abort 'the clock groups in the input sdc do not include rtc_clk'
s.sub!(/-multiply_by 16 -divide_by 1 \[get_nets \{core_clk\}\]/,
       '-multiply_by 4 -divide_by 5 [get_nets {core_clk}]') or abort 'the input sdc has no core_clk constraint'
s.sub!(/-multiply_by 2 -divide_by 1 \[get_nets \{ahb_clk\}\]/,
       '-multiply_by 1 -divide_by 1 [get_nets {ahb_clk}]') or abort 'the input sdc has no ahb_clk constraint'
# CPU、バス、SDRAM コントローラのクリティカルパスを、クロックごとにレポートに出す (全体の上位 25 本には、違反していないクロックの
# 経路が出ないため。report_timing を書くと全体の表が出なくなるので、SDRAM コントローラのクロック s_clk も追加する)
s << "\n// Hazard3 version: report the critical paths of each clock\n"
%w[core_clk ahb_clk s_clk].each do |c|
  s << "report_timing -setup -from_clock [get_clocks {#{c}}] -to_clock [get_clocks {#{c}}] -max_paths 25 -max_common_paths 1\n"
end
File.write(dst, s)
