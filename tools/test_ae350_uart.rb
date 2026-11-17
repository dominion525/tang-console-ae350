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

  def test_writes_data_from_board_to_output
    out = StringIO.new
    @board.write("== AE350 probe ==\r\n")
    AE350Uart.relay(@port, StringIO.new, out, 0.2)
    assert_equal "== AE350 probe ==\r\n", out.string
  end

  def test_sends_input_to_board
    input_r, input_w = IO.pipe
    input_w.write('x')
    input_w.close
    AE350Uart.relay(@port, input_r, StringIO.new, 0.2)
    assert_equal 'x', @board.read_nonblock(16)
  end

  def test_keeps_receiving_after_input_ends
    out = StringIO.new
    input_r, input_w = IO.pipe
    input_w.close
    t = Thread.new { AE350Uart.relay(@port, input_r, out, 0.4) }
    sleep 0.2
    @board.write('after')
    t.join
    assert_equal 'after', out.string
  end

  def test_stops_after_given_seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AE350Uart.relay(@port, StringIO.new, StringIO.new, 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_in_delta 0.3, elapsed, 0.1
  end

  def test_runs_until_port_closes_without_seconds
    out = StringIO.new
    t = Thread.new { AE350Uart.relay(@port, StringIO.new, out, nil) }
    @board.write('end')
    sleep 0.1
    assert t.alive?
    @board.close
    assert t.join(1), 'did not stop after the port closed'
    assert_equal 'end', out.string
  end

  def test_discards_pending_data
    @board.write('garbage')
    sleep 0.05
    AE350Uart.discard_pending(@port)
    assert_raises(IO::WaitReadable) { @port.read_nonblock(16) }
  end
end
