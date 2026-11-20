a = [1, 2, 3, 4]
p a.any?, a.all?, a.none?, a.one?, [nil, false].any?, [1, nil].all?, [].none?, [1].one?, a.append(6).size, a.prepend(0).size, a.each_index.to_a, [1, 2].cycle(2).to_a, a.dig(0), a.eql?(a), a.sample.class
p a.sort { |x, y| y <=> x }, a.uniq { |x| x % 2 }, a.minmax_by { |x| -x }, a.grep(2..3), a.grep_v(2..3), %w[ab cd].grep(/a/), a * ","
b = [1, 2]
b.unshift(0)
b.prepend(-1)
p b
