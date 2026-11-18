o2 = Object.new
def o2.put(k, v); @h ||= {}; @h[k] = v; end
def o2.get(k) = @h[k]
o2.put(:x, 5)
p o2.get(:x)
