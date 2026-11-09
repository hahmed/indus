def f(x); a = nil; a = [1] if x; a; end
p f(true), f(false)
def g(flag); h = nil; h ||= {} if flag; h; end
p g(true); p g(false)
