seed = 42
i = 0
while i < 400
  seed = (seed * 1103515245 + 12345) % 2147483648
  m = seed.to_f / 2147483648.0
  seed = (seed * 1103515245 + 12345) % 2147483648
  e = seed % 40 - 20
  v = m * 10.0 ** e
  puts v
  puts -v
  puts m
  i = i + 1
end
