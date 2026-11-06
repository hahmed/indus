# an LRU cache: a hash plus an array as the recency list, with stats
class LRU
  attr_reader :hits, :misses
  def initialize(cap)
    @cap = cap
    @store = {}
    @order = []
    @hits = 0
    @misses = 0
  end
  def get(k)
    if @store.key?(k)
      @hits += 1
      touch(k)
      @store[k]
    else
      @misses += 1
      nil
    end
  end
  def put(k, v)
    @store[k] = v
    touch(k)
    evict while @order.size > @cap
    self
  end
  def touch(k)
    @order.delete(k)
    @order.push(k)
  end
  def evict
    old = @order.shift
    @store.delete(old)
  end
  def keys = @order.dup
  def size = @store.size
  def to_s = "LRU(#{size}/#{@cap}) #{@order.join(',')} hits=#{@hits} misses=#{@misses}"
end

c = LRU.new(3)
c.put("a", 1).put("b", 2).put("c", 3)
puts c.to_s
puts c.get("a").inspect
c.put("d", 4)
puts c.to_s
puts c.get("b").inspect
puts c.keys.inspect
puts c.size
%w[a c d e].each { |k| print c.get(k).inspect, " " }
puts
puts "#{c.hits} #{c.misses}"
