# the seam: one method is redefined at runtime from a string; everything
# else in the program is compiled statically
class Greeter
  def initialize(k)
    @k = k
  end
  def hello(n)
    n + @k
  end
  def bye(n)
    n - 1
  end
end

g = Greeter.new(1)
i = 0
total = 0
while i < 1000000
  total = total + g.hello(i) + g.bye(i)
  i = i + 1
end
puts total

Greeter.class_eval "def hello(n) n * 2 + @k end"

i = 0
total = 0
while i < 1000000
  total = total + g.hello(i) + g.bye(i)
  i = i + 1
end
puts total
