# priority queue + Dijkstra on a small graph: nested arrays, sorting, Float::INFINITY
class Heap
  def initialize = @a = []
  def size = @a.size
  def empty? = @a.empty?
  def push(prio, item)
    @a.push([prio, item])
    i = @a.size - 1
    while i > 0
      parent = (i - 1) / 2
      break if @a[parent][0] <= @a[i][0]
      tmp = @a[parent]; @a[parent] = @a[i]; @a[i] = tmp
      i = parent
    end
    self
  end
  def pop
    return nil if @a.empty?
    top = @a[0]
    last = @a.pop
    unless @a.empty?
      @a[0] = last
      i = 0
      loop do
        l = i * 2 + 1
        r = l + 1
        small = i
        small = l if l < @a.size && @a[l][0] < @a[small][0]
        small = r if r < @a.size && @a[r][0] < @a[small][0]
        break if small == i
        tmp = @a[small]; @a[small] = @a[i]; @a[i] = tmp
        i = small
      end
    end
    top
  end
end

GRAPH = {
  "a" => [["b", 7], ["c", 9], ["f", 14]],
  "b" => [["a", 7], ["c", 10], ["d", 15]],
  "c" => [["a", 9], ["b", 10], ["d", 11], ["f", 2]],
  "d" => [["b", 15], ["c", 11], ["e", 6]],
  "e" => [["d", 6], ["f", 9]],
  "f" => [["a", 14], ["c", 2], ["e", 9]],
}

def dijkstra(graph, from)
  dist = {}
  graph.each_key { |k| dist[k] = 1_000_000 }
  dist[from] = 0
  heap = Heap.new
  heap.push(0, from)
  until heap.empty?
    d, node = heap.pop
    next if d > dist[node]
    graph[node].each do |(nbr, w)|
      nd = d + w
      if nd < dist[nbr]
        dist[nbr] = nd
        heap.push(nd, nbr)
      end
    end
  end
  dist
end

d = dijkstra(GRAPH, "a")
d.keys.sort.each { |k| puts "#{k}: #{d[k]}" }
puts d.values.sum
h = Heap.new
[5, 3, 8, 1].each_with_index { |p, i| h.push(p, "item#{i}") }
puts h.size
3.times { puts h.pop.inspect }
