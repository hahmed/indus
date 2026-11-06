add = ->(a, b) { a + b }
mul = ->(a, b) { a * b }
ops = { "add" => add, "mul" => mul }
puts ops["add"].call(3, 4)
puts ops["mul"].call(3, 4)
k = 10
scale = ->(x) { x * k }
puts scale.call(5)
def apply(f, v)
  f.call(v)
end
puts apply(scale, 7)
double = ->(x) { x * 2 }
puts apply(double, 7)
fs = [double, scale]
i = 0
while i < 2
  puts fs[i].call(3)
  i = i + 1
end
puts [1, 2, 3].map { |x| double.call(x) }.inspect
sq = lambda { |x| x * x }
inc = proc { |x| x + 1 }
puts sq.call(6)
puts inc.call(6)
puts apply(sq, 9)
