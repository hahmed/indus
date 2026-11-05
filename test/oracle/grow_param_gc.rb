def fill(a, n)
  i = 0
  while i < n
    a.push("s" + i.to_s)
    i += 1
  end
end
200.times do
  z = []
  fill(z, 50)
  raise "bad" if z.length != 50
end
puts "ok"
