def kw(a, b: 2, **rest); [a, b, rest]; end
p kw(1, **{b: 5, d: 6})
h = {b: 7}
p kw(1, **h)
p kw(1, **h, d: 8)
