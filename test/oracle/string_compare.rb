a = "apple"
b = "banana"
c = "app"
puts a == b
puts a != b
puts a != "apple"
puts a < b
puts b < a
puts c < a
puts a <= "apple"
puts "9" >= "0"
puts "a" >= "0" && "a" <= "9"
puts "5" >= "0" && "5" <= "9"
n = 0
s = "x3y"
i = 0
while i < s.length
  ch = s[i]
  n = n + 1 if ch >= "0" && ch <= "9"
  i = i + 1
end
puts n
