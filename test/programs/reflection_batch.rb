class R1; def method_missing(n, *a) = "mm:#{n}"; def respond_to_missing?(n, p = false) = true; end; p R1.new.foo, R1.new.respond_to?(:bar)
class R2; [:a, :b].each_with_index { |n, i| define_method(n) { i } }; end; p R2.new.a, R2.new.b
class R3; def initialize = @h = {}; def method_missing(n, *a) = n.to_s.end_with?("=") ? @h[n.to_s.chomp("=").to_sym] = a[0] : @h[n]; end; a = R3.new; a.foo = 1; p a.foo
class R4; def a = 1; end; p R4.instance_methods(false), R4.method_defined?(:a), R4.new.respond_to?(:a)
class R5; def a = 1; end; R5.send(:define_method, :b) { 2 }; p R5.new.b
class R6; def self.inherited(k) = (@subs ||= []) << k.name; def self.subs = @subs; end; class R6B < R6; end; class R6C < R6; end; p R6.subs
class R7; def a = 1; end; p R7.new.method(:a).call, R7.instance_method(:a).bind(R7.new).call
class R8; def to_proc = proc { |x| x + 1 }; end; p [1, 2].map(&R8.new)
class R9; CONST = 1; end; p R9.const_get(:CONST), R9.constants
