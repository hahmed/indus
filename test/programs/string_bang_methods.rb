s = +"Hello World\n"
p s.chomp!, s, s.chomp!, s.upcase!, s, s.upcase!, s.downcase!, s.swapcase!, s.capitalize!, s
t = +"aaabbb  "
p t.squeeze!, t.rstrip!, t.strip!, t.delete!("b"), t, t.slice!(0), t, t.slice!(0, 1), t
u = +"hello"
p u.sub!("l", "L"), u.gsub!("l", "L"), u.gsub!("z", "y"), u.tr!("L", "x"), u, u.reverse!, u.chop!, u.succ!, u.clear, u
p "aabbcc".tr_s("ab", "xy"), "hello".byteindex("l"), "hello".byteindex("l", 3), "hello".byterindex("l"), "hello".byteslice(1, 2), (+"hello").bytesplice(1, 2, "EL"), "ab".delete_prefix!("a"), "ab".delete_suffix!("x")
