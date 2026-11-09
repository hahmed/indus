class W; attr_reader :s; def initialize = @s = 1; def follow = [s]; def f2 = s; end
class P < W; def s = -1; end
p W.new.follow, P.new.follow, P.new.f2, P.new.s
