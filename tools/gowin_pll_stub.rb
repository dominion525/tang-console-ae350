# ボードの回路 (board/tang_console/) を lint にかけるために、Gowin のプリミティブ PLL の空のモジュール (スタブ) を作る。
# Gowin のシミュレーションモデル (simlib/gw5a/prim_sim.v) から、module PLL の先頭 (ポートの並び) と、
# ポートとパラメータの宣言だけを取り出し、出力を 0 にしたモジュールを書き出す。Gowin のファイルから作るので、出力先は build/
# (コミットしない)。
#
#   ruby tools/gowin_pll_stub.rb <prim_sim.v> <出力>

src, out = ARGV
abort 'usage: ruby tools/gowin_pll_stub.rb <prim_sim.v> <output>' if src.nil? || out.nil?

lines = File.readlines(src)
start = lines.index { |l| l =~ /^module PLL\s*\(/ } or abort 'module PLL not found'

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
abort 'no outputs found' if outputs.empty?

File.write(out, <<~V)
  // tools/gowin_pll_stub.rb が #{File.basename(src)} の module PLL から作った、中身の無いモジュール (= lint のため)
  #{head.join}#{decls.join}#{outputs.map { |o| "assign #{o} = 1'b0;\n" }.join}endmodule
V
puts "#{out}: #{decls.size} declaration lines, outputs #{outputs.join(' ')}"
