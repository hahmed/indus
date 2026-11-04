class Num
  attr_reader :v
  def initialize(v)
    @v = v
  end
end
class Add
  attr_reader :l, :r
  def initialize(l, r)
    @l = l
    @r = r
  end
end
class Pair
  attr_reader :head, :tail
  def initialize(h, t)
    @head = h
    @tail = t
  end
end

def visit(node)
  case node
  when Num then node.v
  when Add then visit(node.l) + visit(node.r)
  else 0
  end
end

def count(lst)
  n = 0
  cur = lst
  while cur != nil && cur.is_a?(Pair)
    n = n + 1
    cur = cur.tail
  end
  n
end

def first_val(x)
  if x.is_a?(Pair) && x.head.is_a?(Num)
    return x.head.v
  end
  -1
end

def not_num(x)
  return 7 unless x.is_a?(Num)
  x.v
end

tree = Add.new(Num.new(2), Add.new(Num.new(3), Num.new(4)))
puts visit(tree)
puts visit(Num.new(9))
lst = Pair.new(Num.new(1), Pair.new(Num.new(2), Pair.new(Add.new(Num.new(1), Num.new(1)), nil)))
puts count(lst)
puts count(nil)
puts first_val(lst)
puts first_val(Num.new(5))
puts first_val(Pair.new(Add.new(Num.new(1), Num.new(1)), nil))
puts not_num(Num.new(3))
puts not_num(tree)
