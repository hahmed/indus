puts "hello".squeeze
puts "hello".count("l")
puts "hello".index("l"), "hello".rindex("l")
puts "hello".start_with?("he"), "hello".end_with?("lo")
puts "hello".sub("l", "L"), "hello".gsub("l", "L")
puts "Hello".swapcase
puts "hello"[1..3], "hello"[-3..]
puts "hello".chars.inspect, "hello".bytes.first(2).inspect
puts "hello".each_char.to_a.length
puts "a-b_c".tr("-_", "  ")
puts "hello" * 2
puts "hello".insert(2, "XX")
puts "hello".slice(1, 3)
puts "  hi  ".strip, "  hi  ".lstrip + "|", "  hi  ".rstrip + "|"
puts "hello".ljust(8, ".") + "|", "hello".rjust(8, ".")
puts "hello world".partition(" ").inspect
puts "a=1;b=2".split(";").map { |kv| kv.split("=") }.to_h.inspect
puts "%05.1f|%-5s|%+d|%x|%o|%e|%%" % [3.14159, "ab", 5, 255, 8, 12345.678]
puts "abc".succ, "az".next
puts "hello".ord, 104.chr
puts "3.7".to_f + "2".to_i
puts "0x1f".hex, "17".oct, "101".to_i(2)
puts "hello".reverse, "hello".include?("ell")
puts "hello\n".chomp, "hello".chop
puts "hello".each_char.select { |c| "aeiou".include?(c) }.join
puts "snake_case_word".split("_").map.with_index { |w,i| i.zero? ? w : w.capitalize }.join
