class Pt
  attr_reader :x, :y
  def initialize(x, y) = (@x, @y = x, y)
  def ==(o) = o.is_a?(Pt) && x == o.x && y == o.y
  alias eql? ==
  def hash = [x, y].hash
  def to_s = "(#{x},#{y})"
  def inspect = "#<Pt #{x},#{y}>"
end
h = { "k" => "a" }
puts h["k"]
puts h.key?("z")
puts Pt.new(1, 2) == Pt.new(1, 2)
puts [Pt.new(1, 2), Pt.new(1, 2)].uniq.size
p Pt.new(3, 4)
puts "#{Pt.new(5, 6)}"
puts [Pt.new(1,1)].include?(Pt.new(1,1))
