p (1..3).each_with_object([]) { |i, a| a.unshift(i) }
p [1, 2].each_with_object([]) { |i, a| a.prepend(i) }
