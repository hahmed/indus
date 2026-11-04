class Rng
  def initialize
    @x = 7
  end
  def rand
    @x = (@x * 31 + 3) % 1000
    @x
  end
end
RAND = Rng.new
puts RAND.rand
puts RAND.rand

module Field
  P = 97
  def self.add(a, b) = (a + b) % P
  def self.pow(a, e)
    r = 1
    while e > 0
      r = (r * a) % P
      e = e - 1
    end
    r
  end
  def self.inv(a) = pow(a, P - 2)
end
puts Field.add(90, 10)
puts Field.pow(2, 10)
puts Field.inv(3)

i = 0
while i < 3
  i = i.succ
  result = i * 10
end
puts result
p 1, "two", 3
puts 41.succ
