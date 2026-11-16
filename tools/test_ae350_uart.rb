# tools/ae350_uart.rb のテスト。
# シリアルポートの代わりに UNIX ドメインソケットの組を使い、中継と読み捨ての動作を確かめる。
# 速度の設定（stty と IOSSIOSPEED）は実機のシリアルポートでしか確かめられないので、ここでは扱わない。
#   ruby tools/test_ae350_uart.rb

require 'minitest/autorun'
require 'socket'
require 'stringio'
require_relative 'ae350_uart'

class AE350UartTest < Minitest::Test
  def setup
    @port, @board = UNIXSocket.pair
  end

  def teardown
    [@port, @board].each { |s| s.close unless s.closed? }
  end

  def test_ボードから届いたデータを出力に出す
    out = StringIO.new
    @board.write("== AE350 probe ==\r\n")
    AE350Uart.relay(@port, StringIO.new, out, 0.2)
    assert_equal "== AE350 probe ==\r\n", out.string
  end

  def test_入力をボードに送る
    input_r, input_w = IO.pipe
    input_w.write('x')
    input_w.close
    AE350Uart.relay(@port, input_r, StringIO.new, 0.2)
    assert_equal 'x', @board.read_nonblock(16)
  end

  def test_入力が終わっても受信を続ける
    out = StringIO.new
    input_r, input_w = IO.pipe
    input_w.close
    t = Thread.new { AE350Uart.relay(@port, input_r, out, 0.4) }
    sleep 0.2
    @board.write('after')
    t.join
    assert_equal 'after', out.string
  end

  def test_秒数を指定するとその時間で終わる
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AE350Uart.relay(@port, StringIO.new, StringIO.new, 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_in_delta 0.3, elapsed, 0.1
  end

  def test_秒数を指定しないとポートが閉じるまで続ける
    out = StringIO.new
    t = Thread.new { AE350Uart.relay(@port, StringIO.new, out, nil) }
    @board.write('end')
    sleep 0.1
    assert t.alive?
    @board.close
    assert t.join(1), 'ポートが閉じても終わらなかった'
    assert_equal 'end', out.string
  end

  def test_すでに届いているデータを読み捨てる
    @board.write('garbage')
    sleep 0.05
    AE350Uart.discard_pending(@port)
    assert_raises(IO::WaitReadable) { @port.read_nonblock(16) }
  end
end
