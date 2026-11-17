# ROM のローダー (sw/loader.c) のシミュレーションテスト用に、手順ファイル (テストベンチの +uart_script) と期待の出力を作る。
# CRC-32 と長さは送るデータによって変わるので、ここで計算する (Zlib.crc32 は zlib と同じ値)。
#
#   ruby tools/loader_test.rb cmds  <ILM に置く小さなプログラムの .bin> <終了しないプログラムの .bin> <手順> <期待> <作業ディレクトリ>
#   ruby tools/loader_test.rb hello <hello.bin> <hello.dis> <手順> <期待>
#
# cmds: 拒否されるコマンド、GO、タイムアウト、受信エラー、16 バイトの OK と CRC-32、終了しないプログラムの run と、UART の
#       リセットシーケンスによるローダーへの復帰 (rtl/uart_reset_seq.v)、小さなプログラムの run (0x600D で終わる)
# hello: hello (newlib を使う 48 KB のプログラム) を送って run し、出力を比べる
# どちらも、送るときは 1 バイトごとに APB_CLK で 640 サイクル待つ (1 バイト 800 サイクル = 8 µs。実機の 1.25 Mbps と同じ間隔)
# タイムアウトの確認での待ち (P 100000、1 ms) は、シミュレーション用のローダーのタイムアウト (200,000 mcycle = 250 µs) より長い

require 'zlib'

LOAD_AT   = 0x0001_0000
GAP       = 640
RESET_SEQ = [0x1B, 0x1B, 0x61, 0x65, 0x33, 0x35, 0x30, 0x21].pack('C*') # ESC ESC "ae350!"

def ok_line(data) = format('OK %08x %08x', data.bytesize, Zlib.crc32(data))

mode = ARGV.shift
case mode
when 'cmds'
  tiny, hang, script, expected, work = ARGV
  rseq = File.join(work, 'loader_reset_seq.bin')
  File.binwrite(rseq, RESET_SEQ)
  pseq = File.join(work, 'loader_p16_seq.bin')
  dseq = "0123".b + RESET_SEQ + "4567".b   # 16 バイトの中央にリセットシーケンス
  File.binwrite(pseq, dseq)
  h = File.binread(hang)
  p8  = File.join(work, 'loader_p8.bin')
  p15 = File.join(work, 'loader_p15.bin')
  p16 = File.join(work, 'loader_p16.bin')
  d16 = (0...16).map { |i| (i * 37 + 0x60) & 0xFF }.pack('C*')   # ` (0x60) と ~ (0x7E) を含む
  File.binwrite(p8, d16[0, 8])
  File.binwrite(p15, d16[0, 15])
  File.binwrite(p16, d16)
  t = File.binread(tiny)
  File.write(script, <<-S)
W READY
G #{GAP}
# 拒否されるコマンド (データは送らない)
S load 02000000 00000010
W ERR
S load 01fffff0 00000020
W ERR
S load 0001000g 00000010
W ERR
S hello
W ERR
S run 02000000
W ERR
S run 1234
W ERR
# タイムアウト (16 バイトのうち 8 バイトで止める)
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p8}
P 100000
W ERR
# 受信エラー (15 バイトの後に、ストップビットが 0 の 1 バイト。受信側が捨てるので、残りの 1 バイトを待ってタイムアウトになる)
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p15}
B Z
P 100000
W ERR
# 正しく受信する
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p16}
W OK
# データにリセットシーケンスの 8 バイトが含まれていても、受信中は監視を止めるので、リセットがかからない
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{pseq}
W OK
# 終了しないプログラムを送って実行し、UART のリセットシーケンスで AE350 をリセットして、ローダーに戻す (2 回目の READY)
S load #{format('%08x', LOAD_AT)} #{format('%08x', h.bytesize)}
W GO
F #{hang}
W OK
S run #{format('%08x', LOAD_AT)}
W RUN
P 20000
F #{rseq}
W READY
# ILM の範囲の端 (終端が ILM の外にはみ出す load と、ILM のすぐ外への run)
S load a000fff0 00000020
W ERR
S run a0010000
W ERR
# 小さなプログラムを ILM に送って実行する (0x600D でテストベンチが終わる)
S load a0000000 #{format('%08x', t.bytesize)}
W GO
F #{tiny}
W OK
S run a0000000
  S
  File.write(expected, <<-E)
READY ae350 loader
ERR range
ERR range
ERR syntax
ERR command
ERR range
ERR syntax
GO
ERR timeout
GO
ERR uart
GO
#{ok_line(d16)}
GO
#{ok_line(dseq)}
GO
#{ok_line(h)}
RUN #{format('%08x', LOAD_AT)}
READY ae350 loader
ERR range
ERR range
GO
#{ok_line(t)}
RUN a0000000
  E
when 'hello'
  bin, dis, script, expected = ARGV
  h = File.binread(bin)
  main = File.read(dis)[/^([0-9a-f]{8}) <main>:$/, 1] or abort 'hello.dis に main が無い'
  File.write(script, <<-S)
W READY
G #{GAP}
S load #{format('%08x', LOAD_AT)} #{format('%08x', h.bytesize)}
W GO
F #{bin}
W OK
S run #{format('%08x', LOAD_AT)}
W READY:
S abc
  S
  File.write(expected, <<-E)
READY ae350 loader
GO
#{ok_line(h)}
RUN #{format('%08x', LOAD_AT)}
hello from SDRAM (main 0x#{main})
READY: send one line
received: abc
  E
else
  abort '使い方は先頭のコメント'
end
