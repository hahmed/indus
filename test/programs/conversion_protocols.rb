class V; attr_reader :v; def initialize(v) = @v = v; def coerce(n) = [V.new(n), self]; def +(o) = V.new(@v + o.v); def to_s = "V(#{@v})"; end
puts 5 + V.new(2), V.new(1) + V.new(2)
class B; end
x = ("x" + B.new rescue $!.message)
p x
class P; def to_str = "path"; end
s = "dir/"; s += P.new; p s
p 5 + V.new(2) == 7 rescue p :neq
