s = "aあいうb"
p s.chr, "あ".ord, 12354.chr("UTF-8"), "%c" % 12354, "%c" % "あい", "€5".chr, "".chr, "a".ord, 65.chr, s.chars.map(&:ord)
p s.insert(1, "X"), s
t = "abc"; t.insert(-1, "Z"); p t
p s.chars, s.reverse, s.chop, s.each_char.to_a.size
