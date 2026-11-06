kept = []
i = 0
while i < 2000
  v = i % 3 == 0 ? "s" + i.to_s : (i % 3 == 1 ? [i, "x" + i.to_s] : i)
  kept << v if i % 97 == 0
  i += 1
end
p kept
