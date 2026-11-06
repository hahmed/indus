class Target
  def initialize
    @v = 1
  end
  def v
    @v
  end
  def set(x)
    @v = x
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
p = Proxy.new(Target.new)
p.set(42)
puts p.v
puts p.calls
