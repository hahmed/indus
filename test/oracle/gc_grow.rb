# live set grows past the initial semispace: the collector must double
kept = []
i = 0
while i < 300000
  kept.push("row-" + i.to_s) if i % 3 == 0
  i = i + 1
end
puts kept.length
puts kept[99999]
