a = []; b = []
i = 0
while i < 500
  s = "v" + i.to_s
  a << s
  b << (s + "!") if i % 10 == 0
  i += 1
end
puts a.size, b.size, a[499], b[49]
