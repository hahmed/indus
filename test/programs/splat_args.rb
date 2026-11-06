def two(a, b) = a + b
def splat(*args) = args
def mix(a, *r) = [a, r]
arr = [1, 2]
p two(*arr), splat(*[3, 4]), splat(*[5], 6), splat(), mix(*[7, 8, 9]), mix(0, *[1])
