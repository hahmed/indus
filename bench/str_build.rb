# string building: interpolation, +, to_s, ==, length, in a loop
class Row
  attr_reader :name, :qty
  def initialize(name, qty)
    @name = name
    @qty = qty
  end
  def line
    "#{@name}: " + @qty.to_s + " units"
  end
end

rows = []
i = 0
while i < 100
  rows.push(Row.new("item" + i.to_s, i * 3))
  i = i + 1
end

total = 0
hits = 0
k = 0
while k < 2000
  out = +""
  j = 0
  while j < 100
    l = rows[j].line
    out << l
    out << "\n"
    hits = hits + 1 if l == "item7: 21 units"
    j = j + 1
  end
  total = total + out.length
  k = k + 1
end
puts total
puts hits
puts rows[7].line
