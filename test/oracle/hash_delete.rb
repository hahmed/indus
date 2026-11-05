h = {a: 1, b: 2, c: 3}
puts h.delete(:b)
puts h.inspect
puts h.delete(:zz).inspect
h[:d] = 4
puts h.inspect, h.size
