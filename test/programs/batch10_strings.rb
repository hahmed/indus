s = "hello world"
puts s.getbyte(0)
puts s.getbyte(4)
t = s.dup
t.setbyte(0, 72)
puts t
puts s
puts s.include?("wor")
puts s.include?("xyz")
puts s.start_with?("hell")
puts s.start_with?("world")
parts = "a,b,,c".split(",")
puts parts.length
puts parts[0] + "|" + parts[1] + "|" + parts[2] + "|" + parts[3]
words = "the quick  brown".split(" ")
puts words.length
puts words[2]
bs = "abc".bytes
puts bs.length
puts bs[1]
puts "az".succ
puts "a".b.length
puts "a-b-c".gsub("-", "+")
puts "hello".gsub("l", "L")
