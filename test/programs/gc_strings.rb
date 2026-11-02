kept = []
i = 0
while i < 200000
  s = "item" + i.to_s
  kept.push(s) if i % 50000 == 0
  i = i + 1
end
puts kept.length
puts kept[2]
