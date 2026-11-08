for e in [1, 2, 3] do puts e * 2 end
for a, b in [[1, 2], [3, 4]]; puts a + b; end
$n = 1; $n += 2; $m ||= 7; p $n, $m
T = {}; T["a"] = 1; p T
class B; attr_accessor :v; end; b = B.new; b.v = 1; b.v &&= 5; p b.v
class Outer; class Inner; def hi = "inner"; end; def make = Inner.new; end
p Outer.new.make.hi, Outer::Inner.new.hi
x = 1; p defined?(x), defined?(zz), defined?(puts), defined?(String), defined?(x = 2)
class K; def m = defined?(@a) ? "set" : "unset"; def set = @a = 1; end
k = K.new; p k.m; k.set; p k.m
