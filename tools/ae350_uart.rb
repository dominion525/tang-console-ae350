# Tang Console の AE350 の UART を、端末から読み書きする道具（macOS 専用）。
#   ruby tools/ae350_uart.rb <ポート> [秒数]
#
# 受信したデータを標準出力に出し、標準入力から読んだデータを送信する。
# 秒数を指定するとその時間で終了し、指定しなければ Ctrl-C で終了する。
# 標準入力が終わっても、受信は続ける。
#
# 読み出しプログラム（sw/probe.c）は、1 文字受け取るたびに値を出し直す。
# ただし起動直後の時間計測（約 10 秒）が終わるまでは受け取らないので、書き込んだ直後に全体を読むには 15 秒ほど待つ。
#   printf x | ruby tools/ae350_uart.rb <ポート> 15
#
# UART の速度は 1,250,000 bps。
# macOS の stty は 230400 bps を超える速度を受け付けないため、115200 bps の raw モードで開いてから、IOSSIOSPEED で速度を
# 設定し直す。IOSSIOSPEED はポートを開いている間だけ有効なので、同じファイルディスクリプタで送受信する。
# 速度を変える前に受信したデータは、速度が合っていないので捨てる。

module AE350Uart
  IOSSIOSPEED = 0x80085402
  BAUD        = 1_250_000

  module_function

  # macOS のシリアルポートを 1,250,000 bps で開く
  def open_port(path)
    port = File.open(path, File::RDWR | File::NOCTTY)
    system("stty -f #{path} 115200 cs8 -cstopb -parenb raw -echo -crtscts clocal") or abort 'stty に失敗した'
    port.ioctl(IOSSIOSPEED, [BAUD].pack('Q'))
    port.sync = true
    discard_pending(port)
    port
  end

  # すでに届いているデータを読み捨てる
  def discard_pending(io)
    sleep 0.05
    loop { io.read_nonblock(4096) }
  rescue IO::WaitReadable, EOFError
    nil
  end

  # ポートと端末の間でデータを中継する。sec を指定するとその秒数で終わり、nil ならポートが閉じるまで続ける
  def relay(port, input, output, sec)
    reader = Thread.new do
      loop { output.write(port.readpartial(4096)) }
    rescue EOFError, IOError
      nil
    end
    writer = Thread.new do
      loop { port.write(input.readpartial(4096)) }
    rescue EOFError, IOError
      nil
    end
    sec ? sleep(sec) : reader.join
  ensure
    reader&.kill
    writer&.kill
  end
end

if $PROGRAM_NAME == __FILE__
  path, sec = ARGV
  abort '使い方: ruby tools/ae350_uart.rb <ポート> [秒数]' if path.nil?
  $stdout.sync = true
  trap('INT') { exit }
  AE350Uart.relay(AE350Uart.open_port(path), $stdin, $stdout, sec && Float(sec))
end
