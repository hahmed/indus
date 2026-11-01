# polymorphic dispatch: an array of three classes, one call site
class Shape
  attr_reader :tag
  def initialize(tag)
    @tag = tag
  end
end

class Circle < Shape
  def initialize(r)
    @tag = 1
    @r = r
  end
  def area
    3 * @r * @r
  end
end

class Square < Shape
  def initialize(s)
    @tag = 2
    @s = s
  end
  def area
    @s * @s
  end
end

class Rect < Shape
  def initialize(w, h)
    @tag = 3
    @w = w
    @h = h
  end
  def area
    @w * @h
  end
end

shapes = []
i = 0
while i < 300
  if i % 3 == 0
    shapes.push(Circle.new(i))
  elsif i % 3 == 1
    shapes.push(Square.new(i))
  else
    shapes.push(Rect.new(i, 2))
  end
  i = i + 1
end

total = 0
tags = 0
k = 0
while k < 20000
  j = 0
  while j < 300
    s = shapes[j]
    total = total + s.area
    tags = tags + s.tag
    j = j + 1
  end
  k = k + 1
end
puts total
puts tags
puts shapes.length
