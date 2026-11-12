class P1; def method_missing(name, *args) = name.to_s.start_with?("find_by_") ? "find by #{name.to_s.sub("find_by_", "")}=#{args[0]}" : super; end; p P1.new.find_by_email("x")
class P2; def m = 1; end; p P2.new.public_send(:m), P2.new.__send__(:m), P2.instance_method(:m).bind_call(P2.new)
class P3; def self.[](x) = new(x); def initialize(x) = @x = x; attr_reader :x; end; p P3[5].x
class P4; def respond_to?(m, p = false) = m == :magic || super; end; p P4.new.respond_to?(:magic), P4.new.respond_to?(:nope)
class P5; def m = 1; end; class P5; alias old_m m; def m = old_m + 1; end; p P5.new.m
class P6; def to_s = "P6!"; def inspect = "#<P6>"; end; puts P6.new; p P6.new; puts "#{P6.new}"; p [P6.new]; puts [P6.new].inspect
