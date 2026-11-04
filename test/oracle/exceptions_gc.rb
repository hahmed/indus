# raises across frames while the collector runs; values live across the begin survive
def deep(n, acc)
  s = "x" + n.to_s
  raise "bottom " + s if n == 0
  deep(n - 1, acc + s.length)
end
keep = []
i = 0
total = 0
while i < 3000
  label = "iter" + i.to_s
  begin
    deep(20, 0)
  rescue RuntimeError => e
    keep.push(label + ":" + e.message) if i % 500 == 0
    total = total + e.message.length + label.length
  end
  i = i + 1
end
puts total
puts keep.length
puts keep[3]
