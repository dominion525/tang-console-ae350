# ボードの回路 (= ae350/board/tang_console/) を lint にかけるための、Gowin の部品 PLL の中身の無いモジュールを作る
# (= 2026-11-12)。Gowin のシミュレーションのモデル (= simlib/gw5a/prim_sim.v) から、module PLL の頭 (= 口の並び) と、
# 口とパラメータの宣言だけを取り出し、出力を 0 にしたモジュールを書く。Gowin のファイルから作るので、置き場は build/
# (= コミットしない)。
#
#   ruby tools/gowin_pll_stub.rb <prim_sim.v> <出力>

src, out = ARGV
abort '使い方: ruby tools/gowin_pll_stub.rb <prim_sim.v> <出力>' if src.nil? || out.nil?

lines = File.readlines(src)
start = lines.index { |l| l =~ /^module PLL\s*\(/ } or abort 'module PLL が無い'

head = []
i = start
loop do
  head << lines[i]
  break if lines[i].include?(');')

  i += 1
end

decls = []
outputs = []
i += 1
while i < lines.size
  l = lines[i].sub(%r{//.*}, '')
  break if l =~ /^\s*(reg|wire|always|assign|initial|endmodule|integer|real|specify)\b/

  if l =~ /^\s*(input|output|parameter)\b/
    decls << l.rstrip + "\n"
    outputs.concat(l.sub(/^\s*output\s*(\[[^\]]*\])?/, '').scan(/\w+/)) if l =~ /^\s*output\b/
  end
  i += 1
end
abort '出力が無い' if outputs.empty?

File.write(out, <<~V)
  // tools/gowin_pll_stub.rb が #{File.basename(src)} の module PLL から作った、中身の無いモジュール (= lint のため)
  #{head.join}#{decls.join}#{outputs.map { |o| "assign #{o} = 1'b0;\n" }.join}endmodule
V
puts "#{out}: 宣言 #{decls.size} 行、出力 #{outputs.join(' ')}"
