# inventory report: Struct, Comparable, sorting, grouping, formatting
Item = Struct.new(:sku, :name, :qty, :price, :category) do
  def total = qty * price
  def to_s = "#{sku.ljust(6)} #{name.ljust(12)} #{qty.to_s.rjust(4)} @ #{format('%8.2f', price)}"
end

class Inventory
  include Enumerable
  def initialize = @items = []
  def add(item) = (@items << item; self)
  def each(&blk) = @items.each(&blk)
  def total_value = sum(&:total)
  def low_stock(threshold = 5) = select { |i| i.qty < threshold }
  def by_category = group_by(&:category)
  def restock!(sku, n)
    item = find { |i| i.sku == sku } or raise KeyError, "no such sku #{sku}"
    item.qty += n
    item
  end
end

inv = Inventory.new
inv.add(Item.new("A100", "widget", 12, 2.5, :hardware))
   .add(Item.new("A200", "gadget", 3, 19.99, :hardware))
   .add(Item.new("B100", "manual", 40, 7.0, :books))
   .add(Item.new("B200", "poster", 2, 3.25, :paper))
   .add(Item.new("C100", "cable", 0, 4.75, :hardware))

puts "Total: #{format('%.2f', inv.total_value)}"
puts "Low stock:"
inv.low_stock.sort_by(&:qty).each { |i| puts "  #{i}" }
puts "By category:"
inv.by_category.sort_by { |cat, _| cat.to_s }.each do |cat, items|
  puts "  #{cat}: #{items.map(&:name).sort.join(', ')} (#{items.sum(&:qty)} units)"
end
inv.restock!("C100", 10)
puts inv.find { |i| i.sku == "C100" }.qty
begin
  inv.restock!("Z999", 1)
rescue KeyError => e
  puts "error: #{e.message}"
end
puts inv.map(&:total).max.round(2)
puts inv.count { |i| i.category == :hardware }
puts inv.min_by(&:price).name
puts inv.sort_by { |i| [-i.total, i.name] }.first(2).map(&:sku).inspect
puts inv.each_with_index.map { |i, k| "#{k}:#{i.sku}" }.join(" ")
puts inv.reduce(0) { |acc, i| acc + i.qty }
puts inv.include?(inv.first), inv.to_a.length, inv.first(2).map(&:sku).inspect
