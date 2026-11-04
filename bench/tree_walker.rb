# A tree-walking interpreter in the shape #282 describes: an untyped Node
# hierarchy, a String-keyed environment, and a visit that recurses through
# polymorphic dispatch. The AST is built once and evaluated many times.
class Num
  attr_reader :v
  def initialize(v)
    @v = v
  end
end

class Var
  attr_reader :name
  def initialize(name)
    @name = name
  end
end

class Add
  attr_reader :l, :r
  def initialize(l, r)
    @l = l
    @r = r
  end
end

class Mul
  attr_reader :l, :r
  def initialize(l, r)
    @l = l
    @r = r
  end
end

class Interp
  def initialize(env)
    @env = env
  end

  def visit(node)
    case node
    when Num then node.v
    when Var then @env[node.name]
    when Add then (visit(node.l) + visit(node.r)) % 1000003
    when Mul then (visit(node.l) * visit(node.r)) % 1000003
    else 0
    end
  end
end

def build(depth, i)
  return Num.new(i % 7 + 1) if depth == 0
  return Var.new("x") if depth == 1 && i % 3 == 0
  if i % 2 == 0
    Add.new(build(depth - 1, i + 1), build(depth - 1, i + 2))
  else
    Mul.new(build(depth - 1, i + 1), build(depth - 1, i + 3))
  end
end

# the program: a table of ASTs, walked repeatedly -- the container read that
# hands `visit` its node is the shape that decides whether this stays boxed
prog = Array.new(64) { |k| build(9, k) }
env = { "x" => 3 }
interp = Interp.new(env)

acc = 0
r = 0
while r < 400
  i = 0
  while i < prog.length
    acc = (acc + interp.visit(prog[i])) % 1000003
    i += 1
  end
  r += 1
end
p acc
