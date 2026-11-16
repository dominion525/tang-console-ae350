#!/usr/bin/env ruby
# frozen_string_literal: true

# AE350_SOC のモックと、Gowin のプリミティブ (prim_sim.v) のポートを比べる。
# 名前・向き・幅が 1 つでも違えば、違いを並べて 1 で終わる。
#
#   ruby tools/check_ports.rb <prim_sim.v> <AE350_SOC.v>
#
# prim_sim.v は非 ANSI 形式 (= `input [7:0] APB_CE;`)、モックは ANSI 形式
# (= `input wire [7:0] APB_CE,`) で宣言しているので、それぞれの形で読む。

MODULE = 'AE350_SOC'

# module AE350_SOC から endmodule までの行を返す
def module_body(path)
  lines = File.readlines(path, chomp: true)
  start = lines.index { |l| l =~ /^\s*module\s+#{MODULE}\b/ }
  abort "#{path}: module #{MODULE} が見つからない" unless start
  stop = lines[start..].index { |l| l =~ /^\s*endmodule\b/ }
  lines[start, stop]
end

def normalize_width(width)
  width.to_s.delete(' ')
end

# 宣言の行から { 名前 => [向き, 幅] } を作る
def ports(path)
  decl = %r{^\s*(input|output|inout)\s+(?:wire\s+|reg\s+)?(\[[^\]]*\])?\s*(\w+)\s*[;,]?\s*(?://.*)?$}
  module_body(path).each_with_object({}) do |line, h|
    m = decl.match(line.sub(%r{\s*//.*$}, '')) or next
    dir, width, name = m.captures
    abort "#{path}: #{name} が 2 回宣言されている" if h.key?(name)
    h[name] = [dir, normalize_width(width)]
  end
end

prim_path, mock_path = ARGV
abort 'usage: check_ports.rb <prim_sim.v> <AE350_SOC.v>' unless prim_path && mock_path

prim = ports(prim_path)
mock = ports(mock_path)

errors = []
(prim.keys - mock.keys).each { |n| errors << "モックに無い: #{n} #{prim[n].join(' ')}" }
(mock.keys - prim.keys).each { |n| errors << "プリミティブに無い: #{n} #{mock[n].join(' ')}" }
(prim.keys & mock.keys).each do |n|
  errors << "違う: #{n} プリミティブ #{prim[n].join(' ')} / モック #{mock[n].join(' ')}" if prim[n] != mock[n]
end

puts "プリミティブ #{prim.size} 本 / モック #{mock.size} 本"
if errors.empty?
  puts 'ポートは一致した'
else
  puts errors
  exit 1
end
