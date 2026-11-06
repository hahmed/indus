kept = []
i = 0
while i < 2000
  row = [i, "r" + i.to_s, [i, i + 1]]
  kept << row if i % 100 == 0
  i += 1
end
kept.each { |r| puts "#{r[0]} #{r[1]} #{r[2].inspect}" }
