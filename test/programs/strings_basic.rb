a = "hello"
b = "world"
c = a + " " + b
puts c
puts c.length
n = 42
puts "n is #{n}!"
puts n.to_s + "x"
s = +""
i = 0
while i < 5
  s << "ab"
  i = i + 1
end
puts s
puts s.length
puts c == "hello world"
puts c == "nope"
puts "ends with newline\n"
puts "two\n\n"
$stderr.puts "to stderr"
puts "to stdout"
