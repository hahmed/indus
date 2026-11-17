class E; def initialize(v) = @v = v; def eq(o) = p(@v == o); end
class Object; def should = E.new(self); end
x = nil
true && false && x = 1
x.should.eq(nil)
class A; def m = 1; private :m; def dm = defined?(m); def dp = defined?(self.m); end
p A.new.dm, A.new.dp, defined?(A.new.m), defined?(Object.print), defined?(@@cv = 2), defined?(B = 2), defined?(Object::B = 3), defined?(x ||= 1)
