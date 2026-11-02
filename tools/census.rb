# Which Prism node types and which method names does a Ruby program use,
# and which of them does Indus lower? tools/census.rb file.rb ...
gem "prism", "= 1.8.2" rescue nil
require "prism"
nodes = Hash.new(0); calls = Hash.new(0)
walk = ->(n) {
  next unless n.is_a?(Prism::Node)
  nodes[n.class.name.sub("Prism::", "")] += 1
  calls[n.name] += 1 if n.is_a?(Prism::CallNode)
  n.compact_child_nodes.each { walk.(_1) }
}
ARGV.each { walk.(Prism.parse(File.read(_1)).value) }
lower = File.read(File.join(__dir__, "../lib/indus/lower.rb"))
supported = nodes.keys.select { lower.include?("Prism::#{_1}") }
puts "node types: #{nodes.size}, lowered: #{supported.size}"
puts "\n-- UNSUPPORTED node types (count):"
nodes.reject { supported.include?(_1) }.sort_by { -_2 }.each { printf "  %-36s %5d\n", _1, _2 }
puts "\n-- most-used call names:"
calls.sort_by { -_2 }.first(60).each_slice(4) { |row| puts "  " + row.map { |(n, c)| "#{n}(#{c})".ljust(22) }.join }
