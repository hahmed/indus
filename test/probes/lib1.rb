a = [5, 3, 8, 1, 9, 2]
h = { "a" => 1, "b" => 2, "c" => 3 }
s = "Hello, World"
p a.min_by { |x| -x }
p a.max_by { |x| -x }
p a.minmax
p a.sum { |x| x * 2 }
p a.each_slice(2).to_a
p a.each_cons(2).to_a
p a.each_slice(4).map(&:sum)
p a.zip([1, 2, 3, 4, 5, 6])
p a.zip(a).map { |x, y| x * y }
p a.sort.reverse
p a.sort_by { |x| -x }.first(2)
p a.take(2), a.drop(4)
p a.first, a.last, a.first(2), a.last(2)
p a.include?(8), a.index(8), a.rindex(8)
p a.count, a.count(3), a.count { |x| x > 4 }
p a.uniq, [1, 1, 2].uniq, a.tally
p a.compact, [nil, 1, nil].compact
p a.rotate, a.rotate(-1), a.rotate(2)
p a.reverse, a.reverse_each.to_a
p a.each_with_index.to_a
p a.inject(:+), a.reduce(1) { |m, x| m * x }, a.inject { |m, x| m + x }
p a.sum, a.min, a.max
p a.find_all { |x| x.even? }, a.reject(&:even?)
p a.partition(&:odd?)
p a.group_by(&:odd?)
p a.chunk_while { |x, y| y == x + 1 }.to_a
p a.each_with_object([]) { |x, m| m << x * 2 }
p a.map.with_index { |x, i| x * i }
p a.map.with_index(1) { |x, i| [i, x] }
p a.each_entry.to_a rescue p :no
p a.filter_map { |x| x * 2 if x.odd? }
p a.sum.fdiv(a.size)
p a.product([1, 2]).size
p a.combination(2).count
p a.flat_map { |x| [x, x] }.size
p a.cycle.first(8)
p a.lazy.map { |x| x * 2 }.select(&:even?).first(2)
p a.step rescue p :nostep
p (1..10).step(3).to_a
p 1.step(10, 4).to_a
p 10.downto(7).to_a, 1.upto(3).to_a
p (1..5).reduce(:*)
p (1..5).each_slice(2).to_a
p (1...5).to_a, (1..5).size, ('a'..'e').to_a
p (1..10).select(&:even?), (1..10).find { |x| x > 3 }
p (1..10).sum, (1..10).min, (1..10).max, (1..10).include?(5)
p (1..10) === 5, (1..10).cover?(11)
p h.keys, h.values, h.size, h.length
p h.key?("a"), h.has_key?("z"), h.value?(2), h.has_value?(9)
p h.key(2), h.invert, h.to_a, h.first, h.first(2)
p h.min_by { |k, v| v }, h.max_by { |k, v| v }, h.sort_by { |k, v| -v }
p h.sum { |k, v| v }, h.count { |k, v| v > 1 }, h.find { |k, v| v == 2 }
p h.map { |k, v| [k, v * 2] }.to_h, h.to_h { |k, v| [k.to_sym, v] }
p h.each_with_object({}) { |(k, v), m| m[v] = k }
p h.select { |k, v| v > 1 }, h.reject { |k, v| v > 1 }, h.filter_map { |k, v| k if v > 1 }
p h.any? { |k, v| v > 2 }, h.all? { |k, v| v > 0 }, h.none? { |k, v| v > 5 }
p h.group_by { |k, v| v.odd? }, h.partition { |k, v| v > 1 }
p h.merge({ "d" => 4 }), h.merge({ "a" => 9 }) { |k, o, n| o + n }
p h.dig("a"), h.fetch("a"), h.fetch("z", 0), h.fetch("z") { |k| k * 2 }
p h.values_at("a", "c"), h.slice("a", "b"), h.except("a")
p h.min_by { |k, v| v }&.first
p h.sort.first, h.sort_by { |k, v| v }.last
p h.each_pair.to_a.size, h.each_key.to_a, h.each_value.to_a
p h.reduce(0) { |m, (k, v)| m + v }
p h.inject(0) { |m, (k, v)| m + v }
p h.sum { |pair| pair[1] }
p h.count, h.empty?, {}.empty?
p h.delete_if { |k, v| v == 3 }, h
p h.keep_if { |k, v| v == 1 }, h
h2 = { "x" => 1 }; h2.store("y", 2); h2["z"] = 3; p h2
p h2.compact, h2.flatten, h2.sum { |k, v| v }
p h2.transform_values { |v| v * 10 }, h2.transform_keys(&:upcase)
p h2.each_with_index.map { |(k, v), i| "#{i}#{k}#{v}" }
p h2.filter_map { |k, v| v if v.odd? }
p h2.find_all { |k, v| v > 1 }
p h2.sort_by { |k, v| -v }.to_h
p h2.default, Hash.new(5).default, Hash.new { |hh, k| hh[k] = k * 2 }[3]
p h2.clear, h2.empty?
p s.upcase, s.downcase, s.swapcase, s.capitalize
p s.length, s.size, s.bytesize, s.reverse
p s.include?("World"), s.start_with?("Hell"), s.end_with?("ld"), s.start_with?("a", "H")
p s.index("o"), s.index("o", 5), s.rindex("o"), s.index("zz")
p s[0], s[-1], s[0, 5], s[0..4], s[7..], s[-5..], s[100], s[1...-1]
p s.split(", "), s.split(""), s.split(/,\s*/), s.split("l"), "a b  c".split, "a,b,,".split(",")
p s.chars.first(3), s.bytes.first(3), s.each_char.to_a.size
p s.sub("World", "Ruby"), s.gsub("l", "L"), s.gsub(/[aeiou]/) { |m| m.upcase }, s.tr("lo", "01"), s.delete("l"), s.squeeze, s.squeeze("l")
p s.count("l"), s.count("lo"), s * 2, s + "!", s.center(20, "*"), s.ljust(15, "."), s.rjust(15, ".")
p "  hi  ".strip, "  hi  ".lstrip, "  hi  ".rstrip, "hi\n".chomp, "hi".chop, "hi!".chomp("!")
p s.chars.sort.join, s.chars.uniq.size, s.chars.tally["l"]
p s.each_char.with_index.select { |c, i| c == "o" }.map(&:last)
p s.scan(/o/).size, s.scan(/[A-Z]/), s =~ /W/, s.match(/W(or)/)[1], s.match?(/x/)
p s.slice(0, 5), s.slice(7..), s.partition(", "), s.rpartition("o")
p s.insert(5, "!!!"), s
p s.replace("new"), s
p "abc".succ, "az".next, "zz".succ, "a9".succ
p "abc".ord, 97.chr, "abc".sum, "abc".hash == "abc".hash
p "abc" <=> "abd", "abc" == "abc", "abc".eql?("abc"), "abc".equal?("abc")
p "a-b_c d".tr("-_", "  "), "hello"[1..-2], "hello".each_char.map(&:upcase).join
p "%05d|%-5s|%.2f|%x|%o|%b|%e|%08.3f|%+d" % [42, "ab", 3.14159, 255, 8, 5, 12345.678, 3.14159, 5]
p format("%s and %s", "a", "b"), sprintf("%3d%%", 50), "%c" % 65, "%10.4s|" % "abcdefg"
p "abc".freeze.frozen?, "abc".dup.frozen?, :sym.to_proc.call("x") rescue p :nofreeze
p "snake_case_word".split("_").map(&:capitalize).join, "CamelCase".gsub(/([A-Z])/) { "_" + $1.downcase }
p "hello world".split.map(&:capitalize).join(" "), "a".ljust(3, "-") + "|"
p "hello %s, you are %d" % ["bob", 30]
p "line1\nline2\nline3".lines, "line1\nline2".each_line.map(&:chomp), "a\n\nb".split("\n")
p "hello".start_with?(/h/), "12abc".to_i, "abc".to_i, "3.7xyz".to_f, "0x1A".hex, "777".oct, "1010".to_i(2), "ff".to_i(16), 255.to_s(2), 255.to_s(16)
p "hello"*0, "".empty?, " ".empty?, "a".between?("a", "c"), "abc".casecmp("ABC"), "abc".casecmp?("ABC")
p "hello world".delete_prefix("hello "), "hello world".delete_suffix(" world"), "  a  ".squish rescue p :nosquish
p "ab".unpack("C*") rescue p :nounpack
p "abc".each_byte.to_a, "abc".bytes.sum, "été".bytes.size, "été".length, "été".reverse, "日本".chars
p "abc".encoding.to_s rescue p :noenc
p "abc".force_encoding("ASCII-8BIT").bytes rescue p :noforce
p "Hello World Foo".scan(/\w+/).map(&:length)
p "a1b22c333".scan(/\d+/).map(&:to_i), "a1b22c333".gsub(/\d/, "#"), "key=val; k2=v2".scan(/(\w+)=(\w+)/)
p "The Quick".swapcase, "hello"[10..], "hello"[2..10], "hello".slice(1), "hello".slice(1, 2), "hello".chars.each_slice(2).map(&:join)
