def kw(a:, b: 2, **rest)
  "#{a} #{b} #{rest.inspect}"
end
puts kw(a: 1)
puts kw(a: 1, c: 3)
