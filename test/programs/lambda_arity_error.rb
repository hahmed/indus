l = lambda { 1 }
begin; l.call(0); rescue ArgumentError => e; p e.message; end
l2 = ->(a, b) { a + b }
begin; l2.call(1); rescue ArgumentError => e; p e.message; end
p l2.call(1, 2)
l = lambda { 1 }
begin; p l.call(0); rescue ArgumentError => e; p e.message; end
