require "set"
W = %w[hit hot].freeze
d = Set.new(W)
puts d.size
puts d.include?("hot")
e = Set.new(%w[hit hot])
puts e.size
