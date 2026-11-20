h = {b: 2, a: 1}
p h.sort_by { |k, v| k }.map(&:first), [:b, :a].sort_by { |s| s }, h.min, h.max, h.minmax, h.is_a?(Enumerable), h.each { |k, v| }.class
x = h.reject! { |k, v| v == 1 }
p x
