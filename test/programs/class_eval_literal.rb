class A; def a = 1; end
x = A.new; p x.a
A.class_eval "def a = 2"
p x.a
A.class_eval "def b = 7"
p x.b
A.class_eval "def a = (@z ||= 0; @z += 1)"
p x.a, x.a
A.class_eval <<~RUBY
  def c(n) = n * 3
RUBY
p x.c(4)
p eval("1 + 2")
eval("puts :hi")
