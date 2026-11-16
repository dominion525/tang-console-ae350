# Arora V (= GW5A) の部品のシミュレーション用のモデルを、DQS だけ GW2A のものに差し替えて書き出す。
#
#   ruby prim_sim_gw5a.rb <gw5a の prim_sim.v> <gw2a の prim_sim.v> <書き出す先>
#
# **Gowin EDA の GW5A の DQS のモデルは、ポートとパラメータを並べただけの空の殻で、動きが無い**
# (= 1.9.11.03 で確かめた)。GW2A の DQS のモデルはポートもパラメータも同じなので、それを代わりに使う。
# 「Arora V の DQS は GW2A と同じに動く」という前提に立つので、最後の確かめは実機になる。
#
# 書き出したファイルは Gowin のものなのでコミットしない (= Makefile が tmp/ に作る)。
def find_module(src, name)
  start = src.index(/^\s*module\s+#{name}\b/) or abort "#{name} が見つからない"
  stop = src.index(/^\s*endmodule\b/, start) or abort "#{name} の endmodule が見つからない"
  stop = src.index("\n", stop) || src.size
  [start, stop + 1]
end

gw5a_path, gw2a_path, out_path = ARGV
abort 'usage: ruby prim_sim_gw5a.rb <gw5a prim_sim.v> <gw2a prim_sim.v> <out>' unless out_path

gw5a = File.read(gw5a_path)
gw2a = File.read(gw2a_path)
s5, e5 = find_module(gw5a, 'DQS')
s2, e2 = find_module(gw2a, 'DQS')

merged = gw5a[0...s5] +
         "// DQS: GW5A のモデルは空なので GW2A の prim_sim.v から差し替えた (= cores/ddr3/simulation/prim_sim_gw5a.rb)\n" +
         gw2a[s2...e2] + gw5a[e5..]

# **PLL の出力の位相 (= CLKOUTn_PE_COARSE / CLKOUTn_PE_FINE) を、初期値で入れる** (= 2026-10-27)。
# モデルは位相の指定を `always @(*)` で fine_n / coarse_n に読み込むが、固定の指定 (= DYN_PEn_SEL が "FALSE") の側は
# パラメータしか読まないので、このブロックはきっかけを持たず、Icarus でも Verilator でも一度も走らない。fine_n / coarse_n は
# initial の 0 のままになり、どの出力も位相 0° で出る (= DDR3 の ck が fclk から 90° 遅れず、Micron のモデルが tIS の違反を出す)。
# initial の 0 を、always @(*) の固定の側と同じ値に書き換える。動的な指定 (= DYN_PEn_SEL が "TRUE") は今のまま always @(*) が受ける。
sp, ep = find_module(merged, 'PLL')
pll = merged[sp...ep]
(0..6).each do |n|
  { "fine_#{n}" => "CLKOUT#{n}_PE_FINE", "coarse_#{n}" => "CLKOUT#{n}_PE_COARSE" }.each do |reg, param|
    from = "\n#{reg} = 0;\n"
    abort "PLL の initial に「#{reg} = 0;」が 1 か所だけある前提が崩れた (= #{pll.scan(from).size} か所)" unless pll.scan(from).size == 1
    pll.sub!(from, "\n#{reg} = (DYN_PE#{n}_SEL == \"FALSE\") ? #{param} : 0;   // prim_sim_gw5a.rb\n")
  end
end
merged[sp...ep] = pll

File.write(out_path, merged)
puts "#{out_path}: GW5A の DQS (#{gw5a[s5...e5].lines.size} 行) を GW2A の DQS (#{gw2a[s2...e2].lines.size} 行) に差し替えた"
puts "#{out_path}: PLL の位相の初期値 (= fine_0〜6、coarse_0〜6 の 14 か所) を、固定の指定の値にした"
