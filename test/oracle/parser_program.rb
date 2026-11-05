# tokenizer + recursive-descent parser + evaluator with a class hierarchy
class Token
  attr_reader :kind, :text
  def initialize(kind, text) = (@kind, @text = kind, text)
  def to_s = "#{kind}(#{text})"
end

class Lexer
  def initialize(src) = (@src, @i = src, 0)
  def tokens
    out = []
    while @i < @src.length
      c = @src[@i]
      if c == " "
        @i += 1
      elsif c >= "0" && c <= "9"
        start = @i
        @i += 1 while @i < @src.length && @src[@i] >= "0" && @src[@i] <= "9"
        out << Token.new(:num, @src[start...@i])
      elsif c >= "a" && c <= "z"
        start = @i
        @i += 1 while @i < @src.length && @src[@i] >= "a" && @src[@i] <= "z"
        out << Token.new(:ident, @src[start...@i])
      elsif "+-*/()=".include?(c)
        out << Token.new(:op, c)
        @i += 1
      else
        raise "unexpected character #{c.inspect} at #{@i}"
      end
    end
    out << Token.new(:eof, "")
    out
  end
end

class Node; end
class Num < Node
  attr_reader :value
  def initialize(v) = @value = v
  def eval(env) = value
  def to_s = value.to_s
end
class Var < Node
  attr_reader :name
  def initialize(n) = @name = n
  def eval(env) = env.fetch(name) { raise NameError, "undefined variable #{name}" }
  def to_s = name
end
class BinOp < Node
  attr_reader :op, :left, :right
  def initialize(op, l, r) = (@op, @left, @right = op, l, r)
  def eval(env)
    l = left.eval(env)
    r = right.eval(env)
    case op
    when "+" then l + r
    when "-" then l - r
    when "*" then l * r
    when "/" then r == 0 ? raise(ZeroDivisionError, "divide by zero") : l / r
    end
  end
  def to_s = "(#{left} #{op} #{right})"
end
class Assign < Node
  attr_reader :name, :expr
  def initialize(n, e) = (@name, @expr = n, e)
  def eval(env) = env[name] = expr.eval(env)
  def to_s = "#{name} = #{expr}"
end

class Parser
  def initialize(tokens) = (@toks, @pos = tokens, 0)
  def peek = @toks[@pos]
  def advance = (@pos += 1; @toks[@pos - 1])
  def expect(kind, text = nil)
    t = advance
    raise "expected #{kind} #{text}, got #{t}" unless t.kind == kind && (text.nil? || t.text == text)
    t
  end
  def parse_statement
    if peek.kind == :ident && @toks[@pos + 1].kind == :op && @toks[@pos + 1].text == "="
      name = advance.text
      advance
      Assign.new(name, parse_expr)
    else
      parse_expr
    end
  end
  def parse_expr
    node = parse_term
    while peek.kind == :op && (peek.text == "+" || peek.text == "-")
      op = advance.text
      node = BinOp.new(op, node, parse_term)
    end
    node
  end
  def parse_term
    node = parse_factor
    while peek.kind == :op && (peek.text == "*" || peek.text == "/")
      op = advance.text
      node = BinOp.new(op, node, parse_factor)
    end
    node
  end
  def parse_factor
    t = advance
    case t.kind
    when :num then Num.new(t.text.to_i)
    when :ident then Var.new(t.text)
    when :op
      if t.text == "("
        e = parse_expr
        expect(:op, ")")
        e
      elsif t.text == "-"
        BinOp.new("-", Num.new(0), parse_factor)
      else
        raise "unexpected #{t}"
      end
    else raise "unexpected #{t}"
    end
  end
end

env = {}
[
  "x = 2 + 3 * 4",
  "y = (x - 4) / 2",
  "x * y - -3",
  "z + 1",
  "10 / (y - 5)",
  "2 +",
  "7 & 3",
].each do |src|
  begin
    toks = Lexer.new(src).tokens
    ast = Parser.new(toks).parse_statement
    puts "#{ast} => #{ast.eval(env)}"
  rescue NameError => e
    puts "name error: #{e.message}"
  rescue ZeroDivisionError => e
    puts "math error: #{e.message}"
  rescue RuntimeError => e
    puts "parse error: #{e.message}"
  end
end
puts env.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
puts Lexer.new("a+b").tokens.map(&:to_s).join(" ")
