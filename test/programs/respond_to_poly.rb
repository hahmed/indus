class A; def tag = "a"; end; class B; def other = 1; end
xs = [A.new, B.new]
xs.each { |x| puts(x.respond_to?(:tag) ? x.tag : "no") }
def f(v) = v.respond_to?(:tag)
p f(A.new), f(B.new)
