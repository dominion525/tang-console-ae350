# AE350 の構成の UART (= USB シリアルの 2 つ目、1,250,000 bps) を読み書きする (= macOS)。
#   ruby tools/ae350_uart.rb <ポート> [秒]
#
# 受けたものを標準出力にそのまま出し、標準入力から来たものをそのまま送る。秒を渡すとその秒数で終わり、渡さなければ Ctrl-C で
# 終わる。標準入力が終わっても、受けるのは続ける。読み出しプログラム (= sw/probe.c) は、何か 1 文字受けると値を出し直すので、
# 始めから読みたいときは 1 文字送る (= `printf x | ruby tools/ae350_uart.rb <ポート> 15`)。
#
# macOS の stty は 230400 を超える速さを受けないので、115200 の生のモードにしてから IOSSIOSPEED で速さを設定し直す
# (= tools/ae350_load.rb と同じ。IOSSIOSPEED は開いている間だけ効くので、同じ fd で送受信する)。速さを変える前に受けた
# byte は、速さが合っていないので捨てる。

IOSSIOSPEED = 0x80085402
BAUD        = 1_250_000

port, sec = ARGV
abort '使い方: ruby tools/ae350_uart.rb <ポート> [秒]' if port.nil?

sp = File.open(port, File::RDWR | File::NOCTTY)
system("stty -f #{port} 115200 cs8 -cstopb -parenb raw -echo -crtscts clocal") or abort 'stty'
sp.ioctl(IOSSIOSPEED, [BAUD].pack('Q'))
sp.sync = true
$stdout.sync = true

# 速さを変える前に受けた byte を捨てる
sleep 0.05
begin
  loop { sp.read_nonblock(4096) }
rescue IO::WaitReadable
  nil # 溜まっていた分を読み切った
end

trap('INT') { exit }

reader = Thread.new do
  loop { $stdout.write(sp.readpartial(4096)) }
rescue EOFError, IOError
  nil
end

Thread.new do
  loop { sp.write($stdin.readpartial(4096)) }
rescue EOFError, IOError
  nil
end

sec ? sleep(Float(sec)) : reader.join
