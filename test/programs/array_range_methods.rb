puts (1..100).sum
puts (1..5).reduce(:*)
puts (1..5).inject { |a, b| a + b }
puts (1..20).select(&:even?).inspect
puts (1..3).to_a.inspect
w = %w[a b a]
puts w.uniq.inspect
puts w.select { |x| x == "a" }.length
puts w.include?("b")
puts w.index("b")
puts [3, 1, 2].max
puts [1, 2, 3].reduce(:+)
puts [1, 2, 3].inject(10) { |s, x| s + x }
puts [1, 2, 3].reverse.inspect
puts [[1], [2, 3]].length
puts [1, 2, 3].first
puts [1, 2, 3].last
puts [1, 2, 3].take(2).inspect
puts %w[b a].sort.join(",")
puts %w[a b].map(&:upcase).inspect
puts [1, 2].map(&:to_s).inspect
puts 10.times.map { |i| i * i }.last
puts 3.times.to_a.inspect
