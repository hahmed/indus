h = {a: 1}
p h.to_s, [1, "x"].to_s, :sym.to_s, "s" + h.to_s
puts h.to_s
h2 = {a: 1, b: 2}
p h2.find_all { |k, v| v > 1 }, h2.member?(:a), h2.entries, h2.zip([1, 2]), h2.each_slice(1).to_a
