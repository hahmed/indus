class Shape
  attr_reader :name
  def initialize(name)
    @name = name
  end
end
class Circle < Shape
  def initialize(r)
    super("circle")
    @r = r
  end
  def area
    @r * @r * 3
  end
end
class Square < Shape
  def area
    4
  end
end
shapes = [Circle.new(2), Square.new("square"), Circle.new(1)]
shapes.each { |s| puts s.name + " " + s.area.to_s }
