# ROM のローダー (= ae350/sw/loader.c) に、SDRAM で動かすプログラムを送って動かす (= macOS、2026-11-12)。
#
#   ruby ae350/tools/ae350_load.rb <ポート> <.bin> [番地 (= 16 進。既定 00010000)]
#
#   1. ポートを 1,250,000 bps で開く
#   2. UART の合図 (= ESC ESC "ae350!"。ae350/rtl/uart_reset_seq.v) を送って AE350 をリセットし、ROM のローダーの
#      READY ae350 loader を待つ (= ボードがローダーで待っていても、プログラムが固まっていても、同じ手順で送れる)。
#      1.5 秒来なければ合図を送り直す (= 3 回まで)
#   3. load を送り、GO を待つ (= ERR ならその返事を出して終わる)
#   4. 中身を送り、OK の長さと CRC-32 を、送ったものと照らす (= 合わなければ run しない)
#   5. run を送り、その後は UART の出力を画面に出し、キーボードの入力を UART に送る。プログラムが終わってローダーに
#      戻る (= READY ae350 loader が来る) か、Ctrl-C で終わる
#
# macOS の stty は 230400 を超える速さを受けないので、115200 の生のモードにしてから IOSSIOSPEED で速さを設定し直す
# (= Lapidary の tools/uart_speed.rb と同じ。IOSSIOSPEED は開いている間だけ効くので、同じ fd で送受信する)。

require 'zlib'

IOSSIOSPEED = 0x80085402
BAUD        = 1_250_000
READY       = 'READY ae350 loader'
RESET_SEQ   = [0x1B, 0x1B, 0x61, 0x65, 0x33, 0x35, 0x30, 0x21].pack('C*') # ESC ESC "ae350!"

port, bin, at = ARGV
abort '使い方: ruby ae350/tools/ae350_load.rb <ポート> <.bin> [番地]' if port.nil? || bin.nil?
data = File.binread(bin)
addr = (at || '00010000').to_i(16)

sp = File.open(port, File::RDWR | File::NOCTTY)
system("stty -f #{port} 115200 cs8 -cstopb -parenb raw -echo -crtscts clocal") or abort 'stty'
sp.ioctl(IOSSIOSPEED, [BAUD].pack('Q'))
sp.sync = true

# 受けた byte を溜める (= 行を待つ処理と、run の後の画面への出力が読む)
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

# 1 行を待って返す (= \r\n を落とす)。sec 秒たっても来なければ nil
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

# want で始まる行を、全体で sec 秒まで待つ (= それ以外の行は読み飛ばす。行が続けて来ても、締め切りは延びない)。
# 来れば行、来なければ nil。ERR で始まる行が来たら、その返事を出して終わる
wait_for = lambda do |want, sec|
  deadline = Time.now + sec
  loop do
    left = deadline - Time.now
    return nil if left <= 0

    l = next_line.call(left)
    return nil if l.nil?
    return l if l.start_with?(want)

    abort "ローダー: #{l}" if l.start_with?('ERR')
  end
end

expect = lambda do |want, sec|
  wait_for.call(want, sec) or abort "ローダーが応えない (= #{want} を #{sec} 秒待った)"
end

# 合図を送って READY を待つ。速さを設定した直後や、ビットストリームを書き込んだ直後は、USB シリアルの機器 (= BL616) が
# 落ち着かず合図が落ちることがあった (= 2026-11-12) ので、少し待ってから送り、READY が来なければ送り直す (= 3 回まで)
ready = ->(sec) { !wait_for.call(READY, sec).nil? }
sleep 0.1
got_ready = (1..3).any? do |n|
  warn "合図を送り直す (= #{n} 回目)" if n > 1
  sp.write(RESET_SEQ)
  ready.call(1.5)
end
abort 'ローダーが応えない (= 合図を 3 回送ったが READY ae350 loader が来ない)' unless got_ready
sp.write(format("load %08x %08x\n", addr, data.bytesize))
expect.call('GO', 2)
t0 = Time.now
sp.write(data)
# 送る時間 (= 1 byte 10 bit) と、読み直しの時間に余裕を見る
ok = expect.call('OK', data.bytesize * 10.0 / BAUD + 5)
len, crc = ok.split[1, 2].map { |x| x.to_i(16) }
abort format('長さが合わない (= 送った %d byte、ローダー %d byte)', data.bytesize, len) if len != data.bytesize
abort format('CRC-32 が合わない (= 送った %08x、ローダー %08x)', Zlib.crc32(data), crc) if crc != Zlib.crc32(data)
warn format('送った: %d byte、CRC-32 %08x、%.2f 秒', data.bytesize, crc, Time.now - t0)

sp.write(format("run %08x\n", addr))
expect.call('RUN', 2)

# キーボードの入力を UART に送る
Thread.new do
  while (l = $stdin.gets)
    sp.write(l)
  end
end

# UART の出力を画面に出す。ローダーに戻ったら終わる
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
      warn 'ローダーに戻った'
      break
    end
  end
rescue Interrupt
  warn '終わる (= Ctrl-C)'
end
