class Node
  attr_accessor :left, :right, :i, :j
  def initialize
    @left = nil
    @right = nil
    @i = 0
    @j = 0
    @tag = "n"
  end
end
def populate(depth, node)
  if depth > 0
    node.left = Node.new
    node.right = Node.new
    populate(depth - 1, node.left)
    populate(depth - 1, node.right)
  end
end
def count(n)
  if n == nil
    0
  else
    1 + count(n.left) + count(n.right)
  end
end
k = 0
while k < 40
  node = Node.new
  populate(10, node)
  k = k + 1
end
root = Node.new
populate(12, root)
puts count(root)
