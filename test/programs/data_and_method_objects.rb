D = Data.define(:x, :y)
a = D.new(1, 2); b = D.new(x: 3, y: 4)
p a.x, b.y, a, a == D.new(1, 2)
case b
in { x: 3, y: } then puts "matched #{y}"
end
case b
in D(x:) then puts "ctor #{x}"
end
def f(x) = x * 2
m = method(:f); p m.call(4), [1, 2].map(&method(:f))
p 10.method(:+).call(5), "ab".method(:upcase).call
