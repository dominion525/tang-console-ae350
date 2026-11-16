# LiteDRAM の版 (= build.sh の MEM=litedram) で、litedram_gen が書き出した litedram_core.v の、DDR3 のクロックを止める信号を
# 受け直す (= 2026-11-17)。
#   ruby retime_litedram_stop.rb <litedram_core.v>      (= その場で書き換える)
#
# DDR3 の PHY の初期化の手順は、DDR3 のクロック (= sys2x_i_clk、PLL の出力) を DHCE で止めて戻す。止める信号 (= crg_stop) は
# init_clk (= 50 MHz) の FF から出て、DHCE は CEN を sys2x_i_clk の立ち下がりで受ける。両者は同じ PLL の系列なので、配置配線は
# この経路を 50 MHz の立ち上がりから 100 MHz の立ち下がりまでの 5 ns で検査し、FPGA の中の DHCE までの配線で setup の違反が出た
# (= 1 か所、-0.859 ns)。crg_stop を sys2x_i_clk の立ち下がりで 1 度受けてから CEN に渡すと、DHCE までは 1 周期 (= 10 ns) になる。
# 止める・戻す時刻は 1 周期遅れるが、手順の各段の間は init_clk で 8 サイクル (= 160 ns) あるので、手順には効かない

path = ARGV[0] or abort 'usage: ruby retime_litedram_stop.rb <litedram_core.v>'
s = File.read(path)

cen = ".CEN    (crg_stop),\n"
abort "DHCE の「#{cen.strip}」が 1 か所だけある前提が崩れた (= #{s.scan(cen).size} か所)" unless s.scan(cen).size == 1
inst = "DHCE DHCE(\n"
abort "「DHCE DHCE(」が 1 か所だけある前提が崩れた (= #{s.scan(inst).size} か所)" unless s.scan(inst).size == 1

s.sub!(cen, ".CEN    (crg_stop_retimed),   // retime_litedram_stop.rb\n")
s.sub!(inst, "// retime_litedram_stop.rb: crg_stop を、DHCE が CEN を受けるのと同じ sys2x_i_clk の立ち下がりで受け直す\n" \
             "reg crg_stop_retimed = 1'd0;\n" \
             "always @(negedge sys2x_i_clk) crg_stop_retimed <= crg_stop;\n\n" + inst)
File.write(path, s)
puts "#{path}: DHCE の CEN を、sys2x_i_clk の立ち下がりで受け直した crg_stop にした"
