def grade(n)
  case n
  when 0 then "zero"
  when 1, 2 then "small"
  when 3..5 then "mid"
  else "big"
  end
end
puts grade(0)
puts grade(2)
puts grade(4)
puts grade(9)
def kind(s)
  case s
  when "a" then 1
  when "b" then 2
  else 0
  end
end
puts kind("b")
puts kind("z")
x = 5
puts "odd" unless x % 2 == 0
unless x > 10
  puts "small"
else
  puts "large"
end
t = true
f = false
puts t
puts f
puts !t
puts t && !f
puts t || f
i = 0
until i >= 3
  i += 1
end
puts i
y = nil
y ||= 7
y ||= 9
puts y
z = 3
z &&= z * 2
puts z
def opt(a, b = 10, c = a + b)
  a + b + c
end
puts opt(1)
puts opt(1, 2)
puts opt(1, 2, 3)
module Geo
  SIDES = 4
  class Pt
    attr_reader :x
    def initialize(x)
      @x = x
    end
  end
end
p1 = Geo::Pt.new(42)
puts p1.x
puts Geo::SIDES
h = {a: 1}
h[:b] ||= 5
h[:a] ||= 100
puts h[:a] + h[:b]
arr = [1, 2, 3]
puts arr.map { _1 * 2 }[2]
sq = ->(v) { v * v }
puts sq.call(6)
puts sq.(7)
