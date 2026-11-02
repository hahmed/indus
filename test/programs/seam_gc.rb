# a method redefined at run time allocates and keeps data; collections must
# run while its frame is live and find the roots above it
class Builder
  def initialize
    @kept = []
    @kept.push("seed") # the element type is visible to the static program
  end
  def kept
    @kept
  end
  def make(i)
    i
  end
end
b = Builder.new
i = 0
while i < 1000
  b.make(i)
  i = i + 1
end
puts b.kept.length

Builder.class_eval "def make(i)
  s = \"item-\" + i.to_s
  j = 0
  while j < 20
    s = s + \"x\"
    j = j + 1
  end
  @kept.push(s) if i % 100 == 0
  s.length
end"

total = 0
i = 0
while i < 200000
  total = total + b.make(i)
  i = i + 1
end
puts total
puts b.kept.length
puts b.kept[7]
