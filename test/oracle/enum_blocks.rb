w = %w[the quick brown fox the end]
puts w.group_by(&:length).keys.sort.inspect
puts w.group_by { |x| x[0] }["t"].inspect
puts w.partition { |x| x.length > 3 }.map(&:length).inspect
puts w.each_with_object({}) { |x, h| h[x] = x.length }.size
puts w.any? { |x| x == "fox" }
puts w.all? { |x| x.length > 2 }
puts w.none? { |x| x.length > 9 }
puts w.find { |x| x.length == 5 }
puts w.find_index { |x| x == "fox" }
puts [[1, 2], [3]].flat_map { |a| a }.inspect
puts w.flat_map(&:chars).length
