class Q0; end
o = Q0.new; def o.greet = "hi"; p o.singleton_methods, o.greet
class Q2; def m = 1; end; a = Q2.new; p a.singleton_class.instance_methods(false); def a.m = 2; p a.m, Q2.new.m
class Q3; def freeze = (puts "frz"; super); end; Q3.new.freeze
klass = Object.const_get(:Array); p klass.new(2, 0)
