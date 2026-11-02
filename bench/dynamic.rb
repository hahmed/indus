# Rails-shaped dynamism: attributes defined in a loop with define_method,
# computed send over a known set of names, and a method_missing proxy.
class Record
  def initialize
    @data = {}
    @data[:price] = 0
    @data[:qty] = 0
    @data[:tax] = 0
  end
  [:price, :qty, :tax].each do |f|
    define_method(f) { @data[f] }
    define_method(:"#{f}=") { |v| @data[f] = v }
  end
  def total
    price * qty + tax
  end
end

class Proxy
  def initialize(target)
    @target = target
    @calls = 0
  end
  def calls
    @calls
  end
  def method_missing(name, *args)
    @calls = @calls + 1
    if args.length == 1
      @target.send(name, args[0])
    else
      @target.send(name)
    end
  end
end

fields = [:price, :qty, :tax]
setters = [:price=, :qty=, :tax=]
r = Record.new
p = Proxy.new(r)
sum = 0
i = 0
while i < 300000
  f = i % 3
  r.send(setters[f], i % 100)
  sum = sum + r.send(fields[f])
  p.price = i % 7
  sum = sum + p.total
  i = i + 1
end
puts sum
puts p.calls
puts r.total
