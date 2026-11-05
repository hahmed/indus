def walk(tree, out)
  return if tree.nil?
  walk(tree[1], out)
  out << tree[0]
  walk(tree[2], out)
end
t = [5, [3, [1, nil, nil], nil], [8, nil, [9, nil, nil]]]
acc = []
walk(t, acc)
puts acc.inspect

def outer(a) = inner(a)
def inner(a) = a.push(42)
q = [1]
outer(q)
outer(q)
puts q.inspect

def add_all(dst, src)
  src.each { |x| dst.push(x) }
  dst.length
end
d = [0]
n = add_all(d, [1, 2])
n = add_all(d, [3])
puts d.inspect, n

def gather(words, out)
  words.each { |w| out.push(w) if w.length > 2 }
end
res = []
gather(%w[a abc de fgh], res)
puts res.inspect

def push_pairs(h, k, v)
  h[k] ||= []
  h[k] << v
end
h = {}
push_pairs(h, "a", 1)
push_pairs(h, "a", 2)
push_pairs(h, "b", 3)
puts h.inspect

class Stack
  def initialize = @items = []
  def push(x) = @items.push(x)
  def pop = @items.pop
  def size = @items.size
end
def fill_stack(s, n) = n.times { |i| s.push(i) }
s = Stack.new
fill_stack(s, 3)
puts s.size, s.pop
