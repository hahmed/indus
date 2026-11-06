s = "hello"
puts s.bytesize
puts s.size
a = [1, 2, 3]
puts a.size
puts 4.even?
puts 7.even?
puts 7.odd?
puts 65.chr + 66.chr
class Acc
  attr_accessor :levar
  def initialize
    @levar = 2
  end
  def total(n)
    sum = 0
    i = 0
    while i < n
      sum = sum + levar
      i = i + 1
    end
    sum
  end
end
puts Acc.new.total(5)
i = 0
odd = 0
while i < 10
  i = i + 1
  next if i % 2 == 0
  odd = odd + i
end
puts odd
puts [1, 2, 3, 4].sum { |x| x * 2 }
puts (1..4).sum { |x| x }
puts [1, 2, 3, 4].count { |x| x > 2 }
puts (-1..1).count { |x| x != 0 }
h = {"a" => 1, "b" => 2}
h.each { |k, v| puts k + "=" + v.to_s }
printf("%d %d\n", 3, 4)
printf("x=%s y=%d\n", "q", 9)
printf("P6\n")
