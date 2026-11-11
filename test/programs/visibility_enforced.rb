class A; protected def p1 = 1; public; def pub = 2; private; def pv = 3; def same(o) = o.p1; end
a = A.new
p a.pub, a.same(A.new)
p((a.pv rescue :nope)); p((a.p1 rescue :nope))
begin; a.pv; rescue NoMethodError => e; puts e.message; end
