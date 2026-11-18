class Object; def should = p(self); end
object = Object.new
class << object
  attr_accessor :a, :b
  def hi(x) = "hi #{x} #{@a}"
end
object.a = 1
object.b = 2
p object.a, object.b, object.hi(3)
o2 = Object.new
class << o2
  def []=(k, v); @h ||= {}; @h[k] = v; end
  def [](k) = @h[k]
end
o2[:x] = 5
p o2[:x]
