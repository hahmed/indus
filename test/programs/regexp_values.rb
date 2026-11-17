re = /b(c)/
s = "abcd"
p s =~ re, re =~ s, s.match(re).to_a, re.match(s).to_a, s.match?(re), re.match?("zz"), s !~ re, s.sub(re, "X"), s.gsub(re, "Y"), s.split(re)
def pick(x) = x ? /a/ : /d/
r = pick(true)
p "cat" =~ r, "dog" =~ pick(false)
