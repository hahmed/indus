def a = @a
def a=(v); @a = v; end
def []=(k, v); (@h ||= {})[k] = v; end
def [](k) = @h[k]
def pm(v); self.a &&= v; end
self.a = 1
pm(5)
p a
self[:x] = 3
p self[:x]
def pm2(k, n); self[k] += n; end
pm2(:x, 4)
p self[:x]
