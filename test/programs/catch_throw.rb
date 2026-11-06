r = catch(:done) do
  10.times { |i| throw :done, i * 10 if i == 3 }
  :never
end
p r
v = catch(:x) { 42 }
p v
def deep(n) = n == 0 ? throw(:out, "bottom") : deep(n - 1)
p catch(:out) { deep(5) }
