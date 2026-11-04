class Msg
  attr_reader :kind, :id
  def initialize(k, i)
    @kind = k
    @id = i
  end
end
cells = []
i = 0
while i < 20000
  cells.push(i % 3 == 0 ? Msg.new("k" + i.to_s, i) : i)
  junk = "pad" + i.to_s
  i = i + 1
end
n = 0
j = 0
while j < cells.length
  v = cells[j]
  n = n + v.id if v.is_a?(Msg)
  j = j + 1
end
puts n
puts cells[3].is_a?(Msg)
parts = ["head"]
k = 0
while k < 3000
  parts.push(k % 2 == 0 ? Msg.new("m", k) : "s" + k.to_s)
  pad = "pad" + k.to_s
  k = k + 1
end
out = 0
parts.each { |p| out = out + (p.is_a?(Msg) ? p.id : p.length) }
puts out
