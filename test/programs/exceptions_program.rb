def each_twice(xs)
  xs.each { |x| yield x; yield x }
end
def first_big(xs)
  each_twice(xs) { |x| return x if x > 5 }
  :none
end
puts first_big([1, 7, 2])
puts first_big([1, 2])

def guarded
  yield
rescue ZeroDivisionError => e
  puts "caught #{e.class}"
  -1
ensure
  puts "cleanup"
end
puts guarded { 10 / 2 }
puts guarded { 10 / 0 }

class ValidationError < StandardError
  attr_reader :field
  def initialize(field, msg = "invalid")
    super("#{field}: #{msg}")
    @field = field
  end
end
def check(h)
  raise ValidationError.new(:name) if h[:name].nil?
  raise ValidationError.new(:age, "too young") if h[:age] < 18
  "ok"
end
[{ name: "a", age: 20 }, { name: "b", age: 3 }, { age: 30 }].each do |h|
  begin
    puts check(h)
  rescue ValidationError => e
    puts "#{e.field} -> #{e.message}"
  end
end

x = Integer("42") rescue 0
puts x
y = (raise "no") rescue "fallback"
puts y
def risky(n)
  raise ArgumentError, "neg" if n < 0
  Math.sqrt(n)
end
puts [4, -1, 9].map { |n| risky(n) rescue nil }.inspect
