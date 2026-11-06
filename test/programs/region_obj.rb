class Node
  attr_accessor :name, :tags, :meta, :next_node
  def initialize(i)
    @name = "n" + i.to_s
    @tags = [i, i * 2, i * 3]
    @meta = { "k" => "v" + i.to_s, "n" => i.to_s }
    @next_node = nil
  end
end
kept = []
i = 0
while i < 3000
  n = Node.new(i)
  n.next_node = n if i % 7 == 0   # a cycle
  kept << n if i % 100 == 0
  i += 1
end
puts kept.size
kept.each { |n| puts "#{n.name} #{n.tags.sum} #{n.meta["k"]} #{n.meta["n"]} #{n.next_node ? n.next_node.name : "-"}" }
