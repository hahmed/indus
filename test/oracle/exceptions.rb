def risky(n)
  raise ArgumentError, "negative" if n < 0
  raise "zero" if n == 0
  n * 2
end
def guarded(n)
  begin
    risky(n)
  rescue ArgumentError => e
    puts "arg: " + e.message
    -1
  rescue => e
    puts "other: " + e.message
    -2
  end
end
puts guarded(5)
puts guarded(-1)
puts guarded(0)
total = 0
i = 0
while i < 1000
  begin
    total = total + risky(i % 3 - 1)
  rescue StandardError
    total = total + 100
  end
  i = i + 1
end
puts total
begin
  puts "body"
  raise "boom"
  puts "not here"
rescue RuntimeError => e
  puts "caught " + e.message
ensure
  puts "ensure runs"
end
x = begin
  risky(21)
rescue
  0
end
puts x
