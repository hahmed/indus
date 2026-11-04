sum = 0
5.times { |i| sum = sum + i }
puts sum
3.upto(6) { |k| sum = sum + k }
puts sum
(1..4).each { |i| sum = sum + i * 10 }
puts sum
a = [3, 1, 4, 1, 5]
t = 0
a.each { |x| t = t + x }
puts t
a.each_with_index { |x, i| t = t + x * i }
puts t
b = a.map { |x| x * 2 }
puts b[0]
puts b[4]
puts b.length
c = 0
10.times do |i|
  next if i % 2 == 0
  break if i > 7
  c = c + i
end
puts c

class Bag
  def initialize
    @items = [10, 20, 30]
  end
  def each
    i = 0
    while i < @items.length
      yield @items[i]
      i = i + 1
    end
  end
  def total
    s = 0
    each { |v| s = s + v }
    s
  end
end
bag = Bag.new
acc = 0
bag.each { |v| acc = acc + v }
puts acc
puts bag.total

def twice(x)
  yield x
  yield x + 1
end
r = 0
twice(5) { |v| r = r + v }
puts r
def pick(n)
  if n > 3
    return yield(n)
  end
  0
end
puts pick(5) { |v| v * 100 }
puts pick(1) { |v| v * 100 }
