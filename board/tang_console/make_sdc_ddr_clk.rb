# DDR_CLK の制約を、ae350_pll の DDR_DIV (DDR_CLK = VCO 800 MHz ÷ DDR_DIV) に合わせて書き換える。
#   ruby make_sdc_ddr_clk.rb <元の制約> <出力先> <DDR_DIV>
#
# top.sdc の ddr_clk は、DDR_DIV が 16 (50 MHz) のときの値 (50 MHz の発振器の 1 倍)。DDR_CLK = 50 MHz × 16 ÷ DDR_DIV なので、
# 倍率を 16 / DDR_DIV (約分したもの) にする

src, dst, div = ARGV
abort 'usage: ruby make_sdc_ddr_clk.rb <input sdc> <output sdc> <DDR_DIV>' unless div
div = Integer(div)
abort 'DDR_DIV must be 5 or more (DDR_CLK must be less than 200 MHz)' if div < 5
g = 16.gcd(div)
s = File.read(src)
s.sub!(/(-name ddr_clk -source \[get_ports \{clk50\}\]) -multiply_by 1 -divide_by 1 /,
       "\\1 -multiply_by #{16 / g} -divide_by #{div / g} ") or abort 'the input sdc has no ddr_clk constraint for 50 MHz'
File.write(dst, s)
