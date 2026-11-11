mod = Module.new { def helper = :h }; class A1; end; A1.include(mod); p A1.new.helper
class A2; end; a = A2.new; a.extend(Module.new { def ext = :e }); p a.ext
class A3; def m = 1; end; A3.prepend(Module.new { def m = super + 10 }); p A3.new.m
k = Class.new(StandardError) { def message = "custom" }; begin; raise k; rescue => e; p e.message; end
k = Class.new { def hi = 1 }
p k.new.hi
