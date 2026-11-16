# Arora V (GW5A) のプリミティブのシミュレーションモデルを、次の 2 点を直して書き出す。DQS は GW2A のものに差し替え、
# PLL は出力の位相の初期値ときっかけ (sensitivity list) を直す。
#
#   ruby prim_sim_gw5a.rb <gw5a の prim_sim.v> <gw2a の prim_sim.v> <出力先>
#
# **Gowin EDA の GW5A の DQS のモデルは、ポートとパラメータを並べただけの空のモジュールで、動作を持たない**
# (1.9.11.03 で確認した)。GW2A の DQS のモデルはポートもパラメータも同じなので、それを代わりに使う。
# 「Arora V の DQS は GW2A と同じに動く」という前提に立つので、最終的な確認は実機で行う。
#
# 書き出したファイルは Gowin のものなのでコミットしない (Makefile が build/ に作る)。
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
         "// DQS: GW5A のモデルは空なので GW2A の prim_sim.v から差し替えた (= tools/prim_sim_gw5a.rb)\n" +
         gw2a[s2...e2] + gw5a[e5..]

# **PLL の出力の位相 (CLKOUTn_PE_COARSE、CLKOUTn_PE_FINE) を、初期値として設定する**。
# モデルは位相の設定を `always @(*)` で fine_n と coarse_n に読み込むが、固定の設定 (DYN_PEn_SEL が "FALSE") の側は
# パラメータしか読まないので、このブロックはきっかけを持たず、Icarus でも Verilator でも一度も実行されない。fine_n と coarse_n は
# initial の 0 のままになり、どの出力も位相 0° で出てしまう。
# そこで initial の 0 を、always @(*) の固定の設定の側と同じ値に書き換える。動的な設定 (DYN_PEn_SEL が "TRUE") は、これまでどおり always @(*) が受ける。
sp, ep = find_module(merged, 'PLL')
pll = merged[sp...ep]
(0..6).each do |n|
  { "fine_#{n}" => "CLKOUT#{n}_PE_FINE", "coarse_#{n}" => "CLKOUT#{n}_PE_COARSE" }.each do |reg, param|
    from = "\n#{reg} = 0;\n"
    abort "PLL の initial に「#{reg} = 0;」が 1 か所だけある前提が崩れた (= #{pll.scan(from).size} か所)" unless pll.scan(from).size == 1
    pll.sub!(from, "\n#{reg} = (DYN_PE#{n}_SEL == \"FALSE\") ? #{param} : 0;   // prim_sim_gw5a.rb\n")
  end
  # 同じ always @(*) は、固定の設定では動的な側の分岐が定数で消え、きっかけが 1 つも残らない (Icarus が
  # 「@* found no sensitivities」を出す)。動的な側が読む fine_dyn_n と coarse_dyn_n を、きっかけとして明示する
  from = "\n// clkout#{n}\n//\nalways @(*)\n"
  abort "PLL に clkout#{n} の always @(*) が 1 か所だけある前提が崩れた (= #{pll.scan(from).size} か所)" unless pll.scan(from).size == 1
  pll.sub!(from, "\n// clkout#{n}\n//\nalways @(fine_dyn_#{n} or coarse_dyn_#{n})   // prim_sim_gw5a.rb\n")
end
merged[sp...ep] = pll

File.write(out_path, merged)
puts "#{out_path}: GW5A の DQS (#{gw5a[s5...e5].lines.size} 行) を GW2A の DQS (#{gw2a[s2...e2].lines.size} 行) に差し替えた"
puts "#{out_path}: PLL の位相の初期値 (= fine_0〜6、coarse_0〜6 の 14 か所) を、固定の指定の値にした"
puts "#{out_path}: PLL の位相を読む always @(*) (= clkout0〜6 の 7 か所) のきっかけを、fine_dyn_n / coarse_dyn_n にした"
