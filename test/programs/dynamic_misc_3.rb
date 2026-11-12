o = Object.new; def o.greet = "hi"; p o.singleton_methods, o.greet
class Q2; def m = 1; end; a = Q2.new; p a.singleton_class.instance_methods(false); def a.m = 2; p a.m, Q2.new.m
module QM3; def self.extended(o) = puts("extended"); end; Object.new.extend(QM3)
class Q4; def freeze = (puts "frz"; super); end; Q4.new.freeze
klass = Object.const_get(:Array); p klass.new(2, 0)
