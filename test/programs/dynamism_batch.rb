A = Class.new { def hi = "h" }
class B; def base = 1; end
C = Class.new(B) { def hi = "h" + base.to_s }
M = Module.new { def mm = 3 }
class D; include M; end
p A.new.hi, C.new.hi, D.new.mm
class E; def a = 1; def initialize = @v = 5; attr_accessor :v; end
E.define_method(:hi) { |x| x * 2 }
e = E.new
p e.hi(3), e.instance_eval { @v + 1 }, e.instance_exec(10) { |k| @v * k + a }
p e.a; E.define_method(:a) { 8 }; p e.a
p e.instance_variable_get(:@v); e.instance_variable_set(:@v, 9); p e.v, e.instance_variables, e.instance_variable_defined?(:@q)
n = "a"; p e.send(n), e.send(:hi, 2)
class F; %w[x y].each { |nm| define_method(nm) { nm.upcase } }; end
p F.new.x, F.new.y
