class A; def inspect = "A!"; def to_s = "a"; end
def f(x) = x ? A.new : nil
p f(true), f(false)
puts f(true), f(false)
F = "%d-%s"; fmt = "<%d|%s>"; puts (fmt rescue F) % [1, "z"]
def g(fmt) = fmt % 5
p g("%03d")
x = [1][5]; p x.is_a?(Integer)
m = "hello".match(/(l)(l)(o)/)
p m.values_at(1..2), m.values_at(1, 3)
