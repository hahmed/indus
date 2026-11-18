@l = lambda { 1 }
@n = 5
f = lambda { @n + 1 }
p f.call
g = lambda { @l.call }
p g.call
