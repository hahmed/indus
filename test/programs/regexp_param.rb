re = /b(c)/
def chk(s, r) = (s =~ r)
p chk("abc", re), chk("zzz", re)
def chk2(s, r) = s.match?(r)
p chk2("abc", re)
