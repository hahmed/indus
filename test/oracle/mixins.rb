module Greets
  def greet
    "hi " + name
  end
  def shout
    greet + "!"
  end
end
module Counts
  def count_up(n)
    @count = (@count || 0) + n
    @count
  end
end
class Person
  include Greets
  include Counts
  attr_reader :name
  def initialize(name)
    @name = name
    @count = 0
  end
end
class Robot
  include Greets
  def name
    "robot"
  end
end
p1 = Person.new("ann")
puts p1.greet
puts p1.shout
puts p1.count_up(3)
puts p1.count_up(4)
r = Robot.new
puts r.shout
class Temp
  include Comparable
  attr_reader :deg
  def initialize(d)
    @deg = d
  end
  def <=>(other)
    deg <=> other.deg
  end
end
puts Temp.new(5) < Temp.new(7)
puts Temp.new(9) > Temp.new(7)
puts Temp.new(7) == Temp.new(7)
puts [3, 1, 2].sort.inspect
