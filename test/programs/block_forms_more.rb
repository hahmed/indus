a = [0, 0, 0]
a.fill { |i| i * 2 }
p a
[1, 2, 3].combination(2) { |c| p c }
[1, 2].cycle(2) { |x| print x }
puts
3.downto(1) { |i| print i }
puts
[1, 2, 3].each_slice(2) { |s| p s }
"ab".each_char { |c| print c }
puts
