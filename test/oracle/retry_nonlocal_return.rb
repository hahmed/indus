attempts = 0
begin
  attempts += 1
  raise "flaky" if attempts < 3
  puts "ok after #{attempts}"
rescue
  retry if attempts < 3
  puts "gave up"
end

def find_first_even(xs)
  xs.each do |x|
    return x if x.even?
  end
  nil
end
puts find_first_even([1, 3, 4, 5])
puts find_first_even([1, 3]).inspect

def first_long(words)
  words.each_with_index do |w, i|
    return "#{w}@#{i}" if w.length > 3
  end
  "none"
end
puts first_long(%w[a bb cccc dd])
puts first_long(%w[a bb])

def total(xs)
  xs.each { |x| return -1 if x < 0 }
  xs.sum
end
puts total([1, 2, 3])
puts total([1, -2, 3])

class Finder
  def initialize(xs) = @xs = xs
  def big
    @xs.each { |x| return x if x > 10 }
    0
  end
end
puts Finder.new([1, 20, 30]).big
puts Finder.new([1, 2]).big
