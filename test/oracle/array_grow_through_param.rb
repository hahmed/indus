def add(a, v)
  a.push(v)
  a << v * 10
  0
end
def fill(a, n)
  i = 0
  while i < n
    a.push(i)
    i += 1
  end
  a
end
x = []
add(x, 1)
add(x, 2)
puts x.inspect
y = fill([], 5)
puts y.inspect
z = [9]
fill(z, 3)
puts z.inspect, z.length
class Bag
  def initialize = @items = []
  def add(v) = @items.push(v)
  def items = @items
end
def stuff(bag, xs)
  xs.each { |x| bag.add(x) }
end
b = Bag.new
stuff(b, [1, 2, 3])
puts b.items.inspect
def collect(out, s)
  s.chars.each { |c| out.push(c.upcase) }
end
w = []
collect(w, "ab")
collect(w, "cd")
puts w.inspect
