# a mixed array survives many collections; every tagged kind is in it
keep = []
i = 0
while i < 20000
  s = "s" + i.to_s
  keep.push(s) if i % 4 == 0
  keep.push(i) if i % 4 == 1
  keep.push(i * 0.5) if i % 4 == 2
  keep.push([i, "x" + i.to_s]) if i % 4 == 3
  junk = "junk" + i.to_s + "padding padding padding"
  i = i + 1
end
puts keep.length
total = 0
j = 0
while j < keep.length
  v = keep[j]
  if v.is_a?(Integer)
    total = total + v
  elsif v.is_a?(Float)
    total = total + 1
  elsif v.is_a?(String)
    total = total + v.length
  elsif v.is_a?(Array)
    total = total + v.length
  end
  j = j + 1
end
puts total
p keep[0]
p keep[1]
p keep[2]
p keep[3]
p keep[19999]
