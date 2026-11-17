def m(*a) = yield(*a)
m(1, 2) { |x, y| p [x, y] }
m(1) { |x, y| p [x, y] }
m(3, 4) { |*r| p r }
m(5) { |x| p x }
def two = yield(1, *[2, 3])
two { |a, b, c| p [a, b, c] }
