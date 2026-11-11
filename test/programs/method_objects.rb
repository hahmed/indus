class A2; def m = 1; end; a = A2.new; p a.public_methods(false).sort, a.method(:m).arity, A2.instance_method(:m).owner
m = 1.method(:+); p m.call(2), m.to_proc.call(3), [1, 2].map(&10.method(:+))
class A; def m = 1; end; obj = A.new; meth = obj.method(:m); p meth.call, meth.owner, meth.receiver == obj, meth.name
