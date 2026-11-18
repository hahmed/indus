class T
  def u3(a, b, c) = [a, b, c]
  def u4(a, b, c, d) = [a, b, c, d]
end
t = T.new
p t.u3(*[1, 2, 3]), t.u4(1, 2, *[3, 4])
x = [7, 8]
p t.u3(6, *x)
