puts "abc".reverse
puts "a-b-c".tr("-", "_")
puts "hello world".split.map(&:capitalize).join(" ")
puts "Hi".downcase
puts "hi".upcase
puts "  x ".strip.length
puts "abc".chars.inspect
puts "abc".each_char.to_a.length
puts "a,b".split(",").inspect
puts "x" * 3
puts "abc"[1]
puts "abc"[0, 2]
puts "abc"[-1]
puts "hello".sub("l", "L")
puts "hello".count("l")
puts "hello".index("l")
puts "hello".end_with?("lo")
puts "hello".ljust(7, ".") + "|"
puts "hello".rjust(7) + "|"
puts "hello".center(9, "*")
