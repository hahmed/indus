puts 10.divmod(3).inspect, (-7).divmod(2).inspect
puts 10.fdiv(4), 10.gcd(4), 10.lcm(4)
puts 10.clamp(1, 5), 2.5.clamp(1, 2)
puts 5.between?(1, 10)
puts 255.digits.inspect, 10.bit_length
puts 3.zero?, 0.zero?, 5.positive?, -5.negative?
puts 1.0 / 0, -1.0 / 0, (0.0 / 0).nan?
puts 10.pred, 10.succ, 7.abs, -7.abs, 7.0.abs
puts 1e3.to_i, 2.5.truncate, 3.99.to_i
puts 100.to_s.rjust(6, "0")
puts Integer.sqrt(17), Math.cbrt(27.0), Math.hypot(3, 4), Math.log2(8), Math.log10(1000), Math.log(Math::E), Math.atan2(1, 1).round(4)
puts rand(1..1), [1].sample, [1,2].shuffle.length
puts [3,1,2].max(2).inspect, [3,1,2].min(2).inspect
puts ["a","bb"].max_by(&:length), ["a","bb"].sum("")
puts [1,2,3].first, [1,2,3].last(2).inspect
puts [1,2,3].include?(2), [1,2,3].none? { |x| x > 5 }, [1,2,3].one? { |x| x > 2 }
puts [1,2,3].tally.inspect, [1,2,3].group_by(&:odd?).inspect
puts [1,2,3].each_slice(2).map(&:sum).inspect
puts [1,2,3].fill(0).inspect, Array.new(3) { |i| i * i }.inspect, Array.new(2, "x").inspect
puts [1,2,3].sum.fdiv(3).round(2), [1,2,3].minmax.inspect
puts [3,1].sort!.inspect, [1,2,3].reverse_each.to_a.inspect
puts [1,2,3].each_with_index.max_by { |x,i| x }.inspect
puts [1,2,3].join("-"), [1,[2,3]].join(",")
puts [1,2,3].first(2).inspect, [1,2,3].drop(1).inspect, [1,2,3].take(2).inspect
puts [1,2,3] & [2,3,4], ([1,2] | [2,3]).inspect, ([1,2,3] - [2]).inspect
puts [[1,:a],[2,:b]].assoc(2).inspect
