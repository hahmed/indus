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
end
def total(c)
  s = 0
  c.each { |v| s = s + v }
  s
end
def first_line(rows)
  out = ""
  rows.each { |r| out = out + r.label + ";" }
  out
end
class Row
  attr_reader :label
  def initialize(l)
    @label = l
  end
end
def make_rows(n)
  rs = []
  i = 0
  while i < n
    rs.push(Row.new("r" + i.to_s))
    i = i + 1
  end
  rs
end
puts total(Bag.new)
puts first_line(make_rows(3))
