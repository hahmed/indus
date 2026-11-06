$count = 0
$name = "g"
def bump
  $count = $count + 1
end
bump
bump
puts $count
puts $name + "!"
class Box
  LIMIT = 3
  EMPTY = [0]
  def initialize(n)
    @n = n
  end
  def full?
    @n >= LIMIT
  end
  def empty_len
    EMPTY.length
  end
end
puts Box.new(5).full?
puts Box.new(1).full?
puts Box.new(1).empty_len
Point = Struct.new(:x, :y)
pt = Point.new(3, 4)
puts pt.x + pt.y
pt.x = 10
puts pt.x
Rec = Struct.new(:v0, :v1, :v2, :levar)
r = Rec.new(1, 2, 3, 1)
puts r.v2 + r.levar
class Swapper
  attr_reader :a, :b, :c
  def initialize
    @a = 1
    @b = 2
    @c = 3
  end
  def rotate
    @a, @b, @c = @b, @c, @a
  end
end
s = Swapper.new
s.rotate
puts s.a + s.b * 10 + s.c * 100
