class Rpn
  OPS = { "+" => :add, "-" => :sub, "*" => :mul }
  def initialize(verbose: false)
    @verbose = verbose
    @stack = []
  end
  def apply(op, *operands, verbose: @verbose)
    puts "apply #{op} #{operands.inspect}" if verbose
    case op
    when "+" then operands.sum
    when "*" then operands.reduce(1) { |a, b| a * b }
    when "-" then operands[0] - operands[1]
    else raise ArgumentError, "bad op #{op}"
    end
  end
  def run(tokens)
    tokens.each do |t|
      if OPS.key?(t)
        b = @stack.pop
        a = @stack.pop
        @stack.push(apply(t, a, b))
      else
        @stack.push(t.to_i)
      end
    end
    @stack.last
  end
end
first, *rest = [1, 2, 3]
puts first
puts rest.inspect
*init, last = [1, 2, 3]
puts init.inspect, last
arr = [1, 2]
puts [*arr, 3].inspect
puts [0, *arr].inspect
r = Rpn.new
puts r.run(%w[3 4 + 2 *])
puts Rpn.new(verbose: true).run(%w[5 1 -])
xs = [3, 1, 2]
xs.sort!
puts xs.inspect
xs.map! { |x| x * 10 }
puts xs.inspect
xs.reverse!
puts xs.inspect
puts 10.to_s(2)
puts 255.to_s(16)
puts "%08.3f" % 3.14159
puts "abc".frozen?
opts = { a: 1 }
merged = { b: 2, **opts }
puts merged.inspect
def kw(a:, b: 2, **rest)
  "#{a} #{b} #{rest.inspect}"
end
puts kw(a: 1)
puts kw(a: 1, c: 3)
begin
  r.apply("/", 1, 2)
rescue ArgumentError => e
  puts "err: #{e.message}"
end
