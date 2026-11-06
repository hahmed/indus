Point = Struct.new(:x, :y) do
  def dist = Math.sqrt(x * x + y * y)
  def to_s = "P(#{x}, #{y})"
end
a = Point.new(3, 4)
p a.dist, a.x, a.to_a, a.members, a == Point.new(3, 4), a.to_s
a.x = 10
p a.x, a[0], a[:y]
P2 = Struct.new(:a, :b, keyword_init: true)
p P2.new(a: 1, b: 2).b
x, y = *a
p x, y
p Point.new(1), Point.members
