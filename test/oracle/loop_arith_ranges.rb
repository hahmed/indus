# a loop counter whose checks are dropped must still produce Ruby's answers
sum = 0
i = 1
while i <= 1000
  sum += i % 7
  i += 1
end
puts sum
n = 0
(1..50).each { |k| n += k * k }
puts n
j = 1000
j -= 3 while j > 0
puts j
a = [5, 4, 3, 2, 1]
k = a.length - 1
acc = 0
while k >= 0
  acc = acc * 10 + a[k]
  k -= 1
end
puts acc
puts (-7) % 3, (-7) / 3, 7 % -3, 7 / -3
puts (0..20).map { |x| x % 4 }.inspect
