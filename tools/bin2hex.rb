#!/usr/bin/env ruby
# frozen_string_literal: true

# バイナリを、$readmemh で読める hex (1 行 1 ワード、32 ビット、リトルエンディアン) に変換する。
#
#   ruby tools/bin2hex.rb <in.bin> <out.hex>

in_path, out_path = ARGV
abort 'usage: bin2hex.rb <in.bin> <out.hex>' unless in_path && out_path

bytes = File.binread(in_path)
bytes += "\0" * ((4 - (bytes.bytesize % 4)) % 4)
File.write(out_path, bytes.unpack('V*').map { |w| format('%08x', w) }.join("\n") << "\n")
