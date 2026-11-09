class A; def a = 1; def swap; def a = 2; end; end
x = A.new; p x.a
class A; def a = 3; end
p x.a, A.new.a
x.swap; p x.a
if true; class A; def a = 9; end; end
p x.a
A.class_eval { def a = 6 }
p x.a
def f = 1
p f
def f = 2
p f
def g(x) = x + 1
p g(1)
if false; def g(x) = x * 100; end
p g(1)
def g(x) = x * 10
p g(1)
