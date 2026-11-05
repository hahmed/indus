def d(v)
  v.class
end
puts d(1)
puts d(Object.new)
puts d("s")
