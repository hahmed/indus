h = {"a" => 1}
puts h["a"]
puts h["zz"]
x = h["zz"]
puts x == nil
puts x != nil
y = h["a"]
puts y == nil
a = Array.new(3, 7)
puts a[5]
puts a[5] == nil
puts a[1] == nil
puts nil
v = a[9]
if v == nil
  puts "missing"
else
  puts v
end
puts h["a"] + 1
names = ["x", "y"]
puts names[5] == nil
puts names[1] == nil
