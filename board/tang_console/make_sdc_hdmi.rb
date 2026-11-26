# HDMI の出力 (build.sh の HDMI=1) のタイミング制約を、元の制約 (build.sh がそれまでに選んだもの) から作る。
#   ruby make_sdc_hdmi.rb <元の制約> <出力先>
#
# HDMI の PLL (hdmi_pll.v) の画素クロック (74.25 MHz) と、その 5 倍のクロック (371.25 MHz、OSER10 の FCLK) を追加する。
# 2 つは同じ PLL の出力で、OSER10 が両方を受けるので、同じグループに入れる。ほかのクロックとは非同期 (HDMI の回路は
# 画素クロックだけで動く。ほかのクロックとの間の経路は、50 MHz で動く PLL_INIT が出す PLL のロックを、画素クロックで
# 同期化するところ (top.v の u_hdmi_rst) と、OSER10 の非同期のリセット。SDRAM 版では、フレームバッファの表示の回路 (rtl/fb_display.v)
# の APB と SDRAM のクロックとの乗せ換え (トグルの 2 段受けと、2 つのクロックのラインバッファ) もある)

src, dst = ARGV
abort 'usage: ruby make_sdc_hdmi.rb <input sdc> <output sdc>' unless dst

s = File.read(src)
s.sub!(/^set_clock_groups -asynchronous (.*)$/) do
  "set_clock_groups -asynchronous #{Regexp.last_match(1)} -group [get_clocks {hdmi_clk hdmi_clk_x5}]"
end or
  abort 'the input sdc has no set_clock_groups line'
s.sub!(/^set_clock_groups /, <<~SDC + 'set_clock_groups ')
  // HDMI clocks (board/tang_console/hdmi_pll.v: 50 MHz / 2 x 27 / 10 = 67.5 MHz, then 67.5 MHz x 11 / 10 = 74.25 MHz and / 2 = 371.25 MHz)
  create_generated_clock -name hdmi_clk -source [get_ports {clk50}] -multiply_by 297 -divide_by 200 [get_nets {hdmi_clk}]
  create_generated_clock -name hdmi_clk_x5 -source [get_ports {clk50}] -multiply_by 297 -divide_by 40 [get_nets {hdmi_clk_x5}]

SDC
File.write(dst, s)
