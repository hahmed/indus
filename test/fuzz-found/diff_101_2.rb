v0 = nil
v1 = nil
v2 = nil
v3 = nil
v4 = nil
puts ("hello".reverse.upcase).split(/(\w)(\w)/).inspect
i = 0
acc = 100.abs
while i < 4
  acc = acc + 3.to_s.to_i
  i += 1
end
puts acc
[-1, 21, 1].join("  pad  ").reverse.split(",").each { |x| puts x.inspect }
class K788
  attr_reader :a, :b
  def initialize(a, b)
    @a = a
    @b = b
  end
  def sum = @a + @b
  def to_s = "K788(#{@a},#{@b})"
  def bump(k)
    @a += k
    self
  end
end
xs = [K788.new(2, -1)]
puts xs.map { |o| o.a + o.b }.inspect

