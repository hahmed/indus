a = 0
b = 1
i = 0
while i < 300
  c = a + b
  a = b
  b = c
  i = i + 1
end
puts a
q = 1
k = 0
while k < 40
  k = k + 1
  q = q * k
end
puts q
puts q / 1000000007
puts q % 1000000007
puts q > 5
puts (q - q) == 0
sum = 0
j = 0
while j < 100
  sum = sum + j * j
  j = j + 1
end
puts sum
