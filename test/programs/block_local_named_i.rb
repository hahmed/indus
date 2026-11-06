arr = (0...3).map do |t|
  s = 0
  i = 0
  while i < 10
    s = s + t
    i = i + 1
  end
  [s, t]
end
puts arr.length
puts arr[1][0]
puts arr[2][1]
[5, 6].each do |x|
  i = 0
  while i < 2
    puts x + i
    i = i + 1
  end
end
3.times do |n|
  i = n * 10
  puts i
end
