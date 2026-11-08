r = catch(:done) do
  10.times { |i| throw :done, i * 10 if i == 3 }
  :never
end
puts r
v = loop do
  break 42
end
puts v
x = [1, 2, 3].each do |i|
  break i * 100 if i == 2
end
puts x
y = [1, 2, 3].map { |i| next 0 if i == 2; i }
p y
i = 0
begin
  i += 1
end while i < 3
puts i
until i == 0 do i -= 1 end
puts i
