module Greet
  def greet = "hi from #{name}"
end
module Loud
  def greet = super.upcase + "!"
end
module Countable
  def count_up = @count = (@count || 0) + 1
end
class Person
  include Greet
  include Countable
  attr_reader :name
  def initialize(name) = @name = name
end
class Shouter < Person
  include Loud
end
p1 = Person.new("ann")
puts p1.greet
puts p1.count_up, p1.count_up
puts Shouter.new("bob").greet

class Robot
  prepend Loud
  def greet = "beep"
end
puts Robot.new.greet

module Util
  def self.double(x) = x * 2
  def triple(x) = x * 3
  module_function :triple
end
puts Util.double(4)
puts Util.triple(4)


module Describable
  def describe = "#{self.class.name}: #{to_s}"
end
class Dog
  include Describable
  def to_s = "rex"
end
puts Dog.new.describe
puts Dog.include?(Describable)
puts Dog.new.is_a?(Describable)
