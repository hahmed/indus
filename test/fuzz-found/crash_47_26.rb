v0 = nil
v1 = nil
v2 = nil
v3 = nil
v4 = nil
module MK698
  def tag = "m"
end
class K698
  include MK698
  include Comparable
  attr_reader :a, :b
  def initialize(a, b)
    @a = a
    @b = b
  end
  def sum = @a + @b
  def <=>(o) = sum <=> o.sum
  def to_s = "K698(#{@a},#{@b})"
  def bump(k)
    @a += k
    self
  end
end
xs = [K698.new(10, 2), K698.new(7, 10)]
puts xs.max.to_s

puts ({:b => [10, 0].max}).inspect
i = 0
acc = [2].select { |x| x == 3 }.group_by { |x| x.to_s }.size
while i < 4
  acc = acc + [1.abs, ((2 + -1) * [4, 0].max)].max
  i += 1
end
puts acc
puts ({:b => 1000}.size.to_f.abs).inspect
