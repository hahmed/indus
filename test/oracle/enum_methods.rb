a = [3, 1, 4, 1, 5, 9, 2, 6]
puts a.each_slice(3).to_a.inspect
puts a.each_cons(7).to_a.length
puts [1, 2].zip(["a", "b"]).inspect
puts a.rotate.first
puts a.drop(5).inspect
puts a.last(2).inspect
puts a.first(2).inspect
puts (a + [7]).length
puts (a - [1]).inspect
puts ([1, 2, 2, 3] & [2, 3]).inspect
puts ([1, 2] | [2, 3]).inspect
puts ([0] * 3).inspect
puts %w[a b a].tally.inspect
puts a.rindex(1)
h = { "a" => 1, "b" => 2 }
puts h.merge({ "c" => 3 }).size
puts h.to_a.inspect
puts h.invert.inspect
puts h.keys.inspect
puts "a\nb".lines.inspect
puts "aabb".squeeze
puts "hello".delete("l")
puts "aBc".swapcase
puts "x\n".chomp + "|"
puts "3.25".to_f
puts "ff".hex
puts 12.gcd(18)
puts 1234.digits.inspect
puts 3.pow(200, 1000)
puts 2.1.ceil
puts -2.1.floor
puts 17.divmod(5).inspect
puts 5.clamp(1, 3)
puts 7.between?(1, 10)
z = [1, 2].zip(["a", "b"])
p z[0]
puts z.inspect
p "a\nb\t\"q\""
puts [1, 2].inspect
puts [[1, 2], [3]].inspect
