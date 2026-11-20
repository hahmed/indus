"a1b2".scan(/\d/) { |m| print m }
puts
p "héy".codepoints, "a\nb".lines, "a|b".lines("|"), "x".prepend("a", "b")
"hé".each_codepoint { |c| print c, " " }
puts
