class A; def a = 1; def z = 0; end
module M; def a = 5; def m = 6; end
x = A.new; y = A.new
def x.a = 9
def x.b = 2
p x.a, x.b, y.a
[x, y].each { |o| p o.a }
z = A.new; z.extend(M); p z.a, z.m, y.a
w = A.new; w.define_singleton_method(:z) { 3 }; p w.z, y.z
