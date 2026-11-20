class P; attr_accessor :x; end
@v, $G = 1, 2
p @v, $G
o = P.new
arr = [0, 0]
o.x, arr[1] = 5, 6
p o.x, arr
(a, b), c = [1, 2], 3
p a, b, c
