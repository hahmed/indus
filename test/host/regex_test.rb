# the regexp compiler (lib/indus/regex.rb) + matcher (rt/regex.rb) under CRuby, against Regexp
require_relative "../../lib/indus/regex"
def __byte_at(s, i) = s.getbyte(i)
def __trap = raise("trap")
src = File.read(File.join(__dir__, "../../lib/indus/rt/regex.rb"))
eval(src.sub(/^class Regexp.*?^end\n/m, "")) # the prelude's Regexp class would shadow CRuby's, which this test compares against

CASES = [
  ["abc", "xxabcxx"], ["a.c", "abc"], ["a.c", "a\nc"], ["^ab", "abx\nab"], ["ab$", "xab\nab"],
  ["\\Aab", "ab"], ["ab\\z", "xab"], ["a*b", "aaab"], ["a+b", "b"], ["a?b", "ab"], ["a{2,3}", "aaaa"],
  ["a{2}", "aaa"], ["a{2,}", "aaaaa"], ["(a|b)+", "abab c"], ["(?:ab)+", "ababx"], ["[a-c]+", "xxabcabcd"],
  ["[^a-c]+", "abcxyzabc"], ["\\d+", "abc123def"], ["\\w+", "  hello_1 "], ["\\s+", "a   b"],
  ["(\\d+)-(\\d+)", "tel 12-345"], ["(a)(b)?", "ac"], ["a.*?b", "aXbXb"], ["a.*b", "aXbXb"],
  ["\\bfoo\\b", "a foo b"], ["\\bfoo\\b", "afoob"], ["(\\w)\\1", "abccd"], ["colou?r", "color colour"],
  ["[.]", "a.b"], ["\\.", "a.b"], ["a|b|c", "xc"], ["(ab|cd)(e|f)", "cdf"], ["x*", "abc"],
  ["[A-Za-z]+", "Hello World"], ["\\d{3}-\\d{4}", "555-1234 x"], ["^$", ""], ["a\\Z", "a\n"],
  ["(\\d+)(?:px|em)", "12em"], ["[\\d.]+", "v1.2.3"], ["\\W+", "a, b"], ["[a-z]+@[a-z]+\\.com", "me@site.com"],
]
bad = 0
CASES.each do |(re, str)|
  prog, ng = Indus::Regex.compile(re)
  ncap = (ng + 1) * 2
  want = Regexp.new(re).match(str)
  caps = __re_caps(ncap)
  at = __re_search(prog, str, 0, caps, ncap)
  got = at < 0 ? nil : __re_groups(str, caps, ncap)
  w = want && (0..ng).map { want[_1] }
  if got != w then bad += 1; puts "MISMATCH /#{re}/ on #{str.inspect}: got #{got.inspect} want #{w.inspect}" end
end
# i flag
prog, ng = Indus::Regex.compile("hello", "i")
caps = __re_caps(4); at = __re_search(prog, "say HeLLo", 0, caps, 4)
(bad += 1; puts "MISMATCH i flag") unless at == 4
# scan / gsub / sub / split
chk = ->(name, got, want) { (bad += 1; puts "MISMATCH #{name}: got #{got.inspect} want #{want.inspect}") unless got == want }
prog, ng = Indus::Regex.compile("\\d+"); nc = (ng + 1) * 2
chk.("scan", __re_scan(prog, nc, "a1b22c333"), "a1b22c333".scan(/\d+/))
chk.("gsub", __re_gsub(prog, nc, "a1b22c333", "#"), "a1b22c333".gsub(/\d+/, "#"))
chk.("sub", __re_sub(prog, nc, "a1b22", "#"), "a1b22".sub(/\d+/, "#"))
chk.("split", __re_split(prog, nc, "a1b22c333d"), "a1b22c333d".split(/\d+/))
prog, ng = Indus::Regex.compile("(\\w+)@(\\w+)"); nc = (ng + 1) * 2
chk.("scan groups", __re_scan_groups(prog, nc, "a@b c@d"), "a@b c@d".scan(/(\w+)@(\w+)/))
chk.("gsub backref", __re_gsub(prog, nc, "a@b c@d", "\\2 at \\1"), "a@b c@d".gsub(/(\w+)@(\w+)/, "\\2 at \\1"))
prog, ng = Indus::Regex.compile("\\s*,\\s*"); nc = (ng + 1) * 2
chk.("split spaces", __re_split(prog, nc, "a , b,c ,d"), "a , b,c ,d".split(/\s*,\s*/))
prog, ng = Indus::Regex.compile("x*"); nc = 2
chk.("gsub empty", __re_gsub(prog, nc, "abc", "-"), "abc".gsub(/x*/, "-"))
chk.("scan empty", __re_scan(prog, nc, "ab"), "ab".scan(/x*/))
prog, ng = Indus::Regex.compile(","); nc = 2
chk.("split trailing", __re_split(prog, nc, "a,b,,"), "a,b,,".split(/,/))
abort "#{bad} mismatches" if bad > 0
puts "ok"
