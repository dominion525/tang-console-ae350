# ROM のローダー (= sw/loader.c) のシミュレーションのテストの、手順のファイル (= TB の +uart_script) と期待の出力を作る
# (= 2026-11-12)。CRC-32 と長さは送る中身で変わるので、ここで計算する (= Zlib.crc32 は zlib と同じ値)。
#
#   ruby tools/loader_test.rb cmds  <ILM に置く小さなプログラムの .bin> <止まらないプログラムの .bin> <手順> <期待> <作業の置き場>
#   ruby tools/loader_test.rb hello <hello.bin> <hello.dis> <手順> <期待>
#
# cmds: 断られる命令、GO、時間切れ、受信の誤り、16 byte の OK と CRC-32、止まらないプログラムの run と UART の合図による
#       ローダーへの戻り (= ae350/rtl/uart_reset_seq.v)、小さなプログラムの run (= 0x600D で終わる)
# hello: hello (= newlib を使う 48 KB) を送って run し、出力を比べる
# どちらも、送るときは byte ごとに APB_CLK 640 サイクル待つ (= 1 byte 800 サイクル = 8 µs。実機の 1.25 Mbps と同じ間隔)
# 時間切れの確認の待ち (= P 100000、1 ms) は、シミュレーション用のローダーの時間切れ (= 200,000 mcycle = 250 µs) より長い

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
  dseq = "0123".b + RESET_SEQ + "4567".b   # 16 byte の真ん中に合図
  File.binwrite(pseq, dseq)
  h = File.binread(hang)
  p8  = File.join(work, 'loader_p8.bin')
  p15 = File.join(work, 'loader_p15.bin')
  p16 = File.join(work, 'loader_p16.bin')
  d16 = (0...16).map { |i| (i * 37 + 0x60) & 0xFF }.pack('C*')   # ` (= 0x60) と ~ (= 0x7E) を含む
  File.binwrite(p8, d16[0, 8])
  File.binwrite(p15, d16[0, 15])
  File.binwrite(p16, d16)
  t = File.binread(tiny)
  File.write(script, <<-S)
W READY
G #{GAP}
# 断られる命令 (= 中身は送らない)
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
# 時間切れ (= 16 byte のうち 8 byte で止める)
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p8}
P 100000
W ERR
# 受信の誤り (= 15 byte の後に、ストップビットが 0 の 1 byte。受ける側が捨てるので、残りの 1 byte を待って時間切れになる)
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p15}
B Z
P 100000
W ERR
# 正しく受ける
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{p16}
W OK
# 中身に合図の 8 byte が並んでいても、受けている間は見張りを止めるので、リセットがかからない
S load #{format('%08x', LOAD_AT)} 00000010
W GO
F #{pseq}
W OK
# 止まらないプログラムを送って動かし、UART の合図で AE350 をリセットして、ローダーへ戻す (= 2 回目の READY)
S load #{format('%08x', LOAD_AT)} #{format('%08x', h.bytesize)}
W GO
F #{hang}
W OK
S run #{format('%08x', LOAD_AT)}
W RUN
P 20000
F #{rseq}
W READY
# ILM の範囲の端 (= 終わりが ILM の外にはみ出す load、ILM のすぐ外への run)
S load a000fff0 00000020
W ERR
S run a0010000
W ERR
# 小さなプログラムを ILM に送って動かす (= 0x600D で TB が終わる)
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
W READY 1
S abc
  S
  File.write(expected, <<-E)
READY ae350 loader
GO
#{ok_line(h)}
RUN #{format('%08x', LOAD_AT)}
hello from SDRAM (main 0x#{main})
READY 1 行を送ってください
受けた行: abc
  E
else
  abort '使い方は先頭のコメント'
end
