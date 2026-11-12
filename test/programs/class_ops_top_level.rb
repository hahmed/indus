class A; def m = 1; def z = 0; end
A.alias_method :n, :m
p A.new.n
A.send(:remove_method, :z)
p A.new.respond_to?(:z)
class B; def m = 1; end
B.class_eval { undef_method :m }
p B.new.respond_to?(:m)
s = Struct.new(:a, :b) { def sum = a + b }
p s.new(1, 2).sum
class C; def each2; yield 1, 2; yield 3, 4; end; def one = yield; end
pr = proc { |a, b| p [a, b] }
C.new.each2(&pr)
C.new.each2 { |a, b| p a + b }
q = proc { 5 }
p C.new.one(&q)
