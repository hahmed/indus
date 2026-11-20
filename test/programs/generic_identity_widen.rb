class Object; def should = E.new(self); end
class E; def initialize(v) = @v = v; def eq(x) = p(@v == x); end
s = "ab"
s.bytes.to_a.should.eq(s.unpack("C*"))
