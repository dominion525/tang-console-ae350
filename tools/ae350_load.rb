# ROM のローダー (sw/loader.c) に、外部メモリか ILM で実行するプログラムを送って実行する (macOS 専用)。
#
#   ruby tools/ae350_load.rb <ポート> <.bin> [アドレス (16 進。既定値 00010000)]
#
#   1. ポートを 1,250,000 bps で開く
#   2. UART のリセットシーケンス (ESC ESC "ae350!"。rtl/uart_reset_seq.v) を送って AE350 をリセットし、ROM のローダーの
#      READY ae350 loader を待つ (ボードがローダーで待機していても、プログラムが固まっていても、同じ手順で送れる)。
#      1.5 秒以内に届かなければ、シーケンスを送り直す (3 回まで)
#   3. load を送り、GO を待つ (ERR ならその応答を出力して終了する)
#   4. データを送り、OK の長さと CRC-32 を、送ったデータと照合する (一致しなければ run しない)
#   5. run を送り、その後は UART の出力を画面に出し、キーボードの入力を UART に送る。プログラムが終了してローダーに
#      戻る (READY ae350 loader が届く) か、Ctrl-C で終了する
#
# macOS の stty は 230400 bps を超える速度を受け付けないので、115200 bps の raw モードにしてから IOSSIOSPEED で速度を設定し直す
# (IOSSIOSPEED はポートを開いている間だけ有効なので、同じファイルディスクリプタで送受信する)。

require 'zlib'

IOSSIOSPEED = 0x80085402
BAUD        = 1_250_000
READY       = 'READY ae350 loader'
RESET_SEQ   = [0x1B, 0x1B, 0x61, 0x65, 0x33, 0x35, 0x30, 0x21].pack('C*') # ESC ESC "ae350!"

port, bin, at = ARGV
abort 'usage: ruby tools/ae350_load.rb <port> <.bin> [address]' if port.nil? || bin.nil?
data = File.binread(bin)
addr = (at || '00010000').to_i(16)

sp = File.open(port, File::RDWR | File::NOCTTY)
system("stty -f #{port} 115200 cs8 -cstopb -parenb raw -echo -crtscts clocal") or abort 'stty'
sp.ioctl(IOSSIOSPEED, [BAUD].pack('Q'))
sp.sync = true

# 受信したバイトを溜める (行を待つ処理と、run の後の画面への出力が読む)
got = ''.b
m = Mutex.new
Thread.new do
  loop do
    c = sp.readpartial(4096)
    m.synchronize { got << c }
  rescue StandardError
    break
  end
end

# 1 行を待って返す (\r\n を除く)。sec 秒たっても届かなければ nil
next_line = lambda do |sec|
  t = Time.now
  loop do
    line = m.synchronize do
      i = got.index("\n")
      i && got.slice!(0..i).force_encoding('UTF-8').scrub.chomp.delete("\r")
    end
    return line if line
    return nil if Time.now - t > sec

    sleep 0.005
  end
end

# want で始まる行を、全体で sec 秒まで待つ (それ以外の行は読み飛ばす。行が続けて届いても、締め切りは延びない)。
# 届けばその行を、届かなければ nil を返す。ERR で始まる行が届いたら、その応答を出力して終了する
wait_for = lambda do |want, sec|
  deadline = Time.now + sec
  loop do
    left = deadline - Time.now
    return nil if left <= 0

    l = next_line.call(left)
    return nil if l.nil?
    return l if l.start_with?(want)

    abort "loader: #{l}" if l.start_with?('ERR')
  end
end

expect = lambda do |want, sec|
  wait_for.call(want, sec) or abort "no response from the loader (waited #{sec} s for #{want})"
end

# リセットシーケンスを送って READY を待つ。速度を設定した直後や、ビットストリームを書き込んだ直後は、USB シリアルの変換チップ (BL616) が
# 安定せずシーケンスが欠けることがあったので、少し待ってから送り、READY が届かなければ送り直す (3 回まで)
ready = ->(sec) { !wait_for.call(READY, sec).nil? }
sleep 0.1
got_ready = (1..3).any? do |n|
  warn "resending the reset sequence (attempt #{n})" if n > 1
  sp.write(RESET_SEQ)
  ready.call(1.5)
end
abort 'no response from the loader (sent the reset sequence 3 times but got no READY ae350 loader)' unless got_ready
sp.write(format("load %08x %08x\n", addr, data.bytesize))
expect.call('GO', 2)
t0 = Time.now
sp.write(data)
# 送信にかかる時間 (1 バイト 10 ビット) と、読み直しにかかる時間に余裕を見る
ok = expect.call('OK', data.bytesize * 10.0 / BAUD + 5)
len, crc = ok.split[1, 2].map { |x| x.to_i(16) }
abort format('length mismatch (sent %d bytes, loader reports %d bytes)', data.bytesize, len) if len != data.bytesize
abort format('CRC-32 mismatch (sent %08x, loader reports %08x)', Zlib.crc32(data), crc) if crc != Zlib.crc32(data)
warn format('sent: %d bytes, CRC-32 %08x, %.2f s', data.bytesize, crc, Time.now - t0)

sp.write(format("run %08x\n", addr))
expect.call('RUN', 2)

# キーボードの入力を UART に送る
Thread.new do
  while (l = $stdin.gets)
    sp.write(l)
  end
end

# UART の出力を画面に出す。ローダーに戻ったら終了する
begin
  pending = ''.b
  loop do
    chunk = m.synchronize do
      s = got.dup
      got.clear
      s
    end
    if chunk.empty?
      sleep 0.01
      next
    end
    $stdout.write(chunk)
    $stdout.flush
    pending << chunk
    pending = pending[-(READY.bytesize + 2)..] || pending if pending.bytesize > 4096
    if pending.include?(READY)
      warn 'returned to the loader'
      break
    end
  end
rescue Interrupt
  warn 'exiting (Ctrl-C)'
end
