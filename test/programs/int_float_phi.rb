x = true ? 1 : 2.0
puts x
y = 0
3.times { |i| y = i.even? ? y + 1 : y + 0.5 }
puts y
