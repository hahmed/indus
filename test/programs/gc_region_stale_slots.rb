# A loop whose body allocates only garbage (so the heap pointer is reset each
# iteration) running over a large live heap, with collections during and after.
# Dead frame slots still holding pointers into reused memory once broke this.
def look(token, table)
  return table[token] if table.key?(token)
  token.to_i
end
keep = []
i = 0
while i < 3000
  keep.push(Array.new(200, i))
  i = i + 1
end
table = {}
i = 0
while i < 64
  table["L" + i.to_s] = i * 3
  i = i + 1
end
sum = 0
i = 0
while i < 20000
  sum = sum + look("L#{i % 64}", table)
  sum = sum + look((i % 100).to_s, table)
  i = i + 1
end
puts sum
more = []
i = 0
while i < 3000
  more.push("s" + i.to_s)
  i = i + 1
end
puts more[2999]
puts keep[1234][5]
