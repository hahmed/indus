[[1, 2], [3, 4]].each { |a, b| p [a, b] }
[[1, [2, 3]]].each { |a, (b, c)| p [a, b, c] }
{a: 1}.each { |k, v| p [k, v] }
[1, 2, 3].each_with_index { |x, i| p [x, i] }
[[1, 2]].map { |a, b| a + b }.then { p _1 }
[1, 2].each { |x, y| p [x, y] }
[[1, 2, 3]].each { |a, *r| p [a, r] }
def m = yield([1, 2]); m { |a, b| p [a, b] }
pr = proc { |a, (b, c)| [a, b, c] }; p pr.call(1, [2, 3])
l = ->(a, b = 2, *r) { [a, b, r] }; p l.(1), l.(1, 5, 6)
