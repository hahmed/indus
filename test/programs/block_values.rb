def twice(&blk)
  blk.call(1) + blk.call(2)
end
puts twice { |x| x * 10 }
def each_pair(a, &blk)
  i = 0
  while i < a.length - 1
    blk.call(a[i], a[i + 1])
    i = i + 1
  end
end
each_pair([1, 2, 3]) { |x, y| puts x + y }
def run(f)
  f.call(5)
end
puts run(->(v) { v + 1 })
triple = ->(x) { x * 3 }
puts [1, 2].map(&triple).inspect
def with_yield(n)
  yield n
  yield n + 1
end
with_yield(7) { |v| puts v }
def pass_through(&b)
  with_yield(1, &b)
end
pass_through { |v| puts v * 100 }
