class A; def initialize(c) = @x = c ? [] : "s"; def go = (@x << "a"; @x << "b"; @x); end
p A.new(true).go
p A.new(false).go
