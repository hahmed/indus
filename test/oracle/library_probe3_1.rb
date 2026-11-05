puts [3,1,2].minmax.inspect
puts [1,2,3,4].each_slice(2).to_a.inspect
puts [1,2,3,4].each_cons(2).to_a.inspect
puts [1,2,3].zip([4,5,6]).inspect
puts [[1,2],[3,4]].transpose.inspect
puts [1,2,3].cycle.first(5).inspect
puts [1,[2,[3]]].flatten.inspect
puts [1,2,3].rotate.inspect
puts [1,2,2,3].uniq.inspect
puts [1,nil,2].compact.inspect
puts [1,2,3].take_while { |x| x < 3 }.inspect
puts [1,2,3].drop_while { |x| x < 2 }.inspect
puts [1,2,3].each_with_index.to_a.inspect
puts [1,2,3].sum { |x| x * 2 }
puts [1,2,3].inject(:+)
puts [1,2,3].product([4,5]).length
puts [1,2,3].combination(2).to_a.inspect
puts [1,2,3].permutation(2).count
puts (1..10).step(3).to_a.inspect
puts 1.step(10, 4).to_a.inspect
puts [1,2,3].chunk_while { |a,b| b == a+1 }.to_a.inspect
puts [1,2,4,5].slice_when { |a,b| b != a+1 }.to_a.inspect
puts %w[a b c].each_with_index.map { |s,i| "#{i}#{s}" }.join(",")
puts [1,2,3].filter_map { |x| x * 2 if x.odd? }.inspect
puts [[1,2],[3,4]].to_h.inspect
puts [[1,2],[3,4]].to_h { |a,b| [b,a] }.inspect
