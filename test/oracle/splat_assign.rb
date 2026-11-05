first, *rest = [1, 2, 3]
puts first
puts rest.inspect
*init, last = [1, 2, 3]
puts init.inspect, last
a, *m, z = [1,2,3,4]
puts m.inspect, z
