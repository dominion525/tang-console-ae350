#!/usr/bin/env ruby
# frozen_string_literal: true

# AE350_SOC の Hazard3 の版と、Gowin のプリミティブ (prim_sim.v) のポートを比べる。
# 名前・向き・幅が 1 つでも違えば、違いを並べて 1 で終わる。
#
#   ruby tools/check_ports.rb <prim_sim.v> <AE350_SOC.v>
#
# prim_sim.v は非 ANSI 形式 (= `input [7:0] APB_CE;`)、Hazard3 の版は ANSI 形式
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

prim_path, hz3_path = ARGV
abort 'usage: check_ports.rb <prim_sim.v> <AE350_SOC.v>' unless prim_path && hz3_path

prim = ports(prim_path)
hz3 = ports(hz3_path)

errors = []
(prim.keys - hz3.keys).each { |n| errors << "Hazard3 の版に無い: #{n} #{prim[n].join(' ')}" }
(hz3.keys - prim.keys).each { |n| errors << "プリミティブに無い: #{n} #{hz3[n].join(' ')}" }
(prim.keys & hz3.keys).each do |n|
  errors << "違う: #{n} プリミティブ #{prim[n].join(' ')} / Hazard3 の版 #{hz3[n].join(' ')}" if prim[n] != hz3[n]
end

puts "プリミティブ #{prim.size} 本 / Hazard3 の版 #{hz3.size} 本"
if errors.empty?
  puts 'ポートは一致した'
else
  puts errors
  exit 1
end
