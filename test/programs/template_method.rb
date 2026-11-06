class A; def hi = "A:" + name + self.class.name; def name = "a"; end
class B < A; def name = "b"; end
puts B.new.hi, A.new.hi
p [A.new, B.new].map(&:hi)
class Base; PREFIX = ">"; def tag = self.class::PREFIX + PREFIX; end
class Child < Base; PREFIX = ">>"; end
puts Base.new.tag, Child.new.tag, Base::PREFIX, Child::PREFIX
