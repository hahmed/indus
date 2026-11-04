class S
  def initialize
    @items = []
  end
  def push(x)
    @items.push(x)
    self
  end
  def size
    @items.size
  end
end
s = S.new
s.push(1).push(2)
puts s.size
