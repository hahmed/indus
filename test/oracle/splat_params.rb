def apply(op, *operands, verbose: false)
  puts operands.inspect if verbose
  operands.sum
end
puts apply("+", 1, 2, 3)
puts apply("*", 2, 3, verbose: true)
def two(a, *r)
  r.length
end
puts two(1)
puts two(1, 2, 3)
