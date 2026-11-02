def matgen(n)
  a = Array.new(n * n, 0.0)
  i = 0
  while i < n
    a[i] = (1.0 / n) * i
    i = i + 1
  end
  a
end
n = 300
a = matgen(n)
b = matgen(n)
puts (a[5] * 1000).to_i
puts (b[7] * 1000).to_i
