class Record
  def initialize
    @data = {}
    @data[:price] = 0
  end
  [:price, :qty].each do |f|
    define_method(f) { @data[f] }
    define_method(:"#{f}=") { |v| @data[f] = v }
  end
end
r = Record.new
r.price = 5
puts r.price
r.send(:qty=, 7)
puts r.send(:qty)
names = [:price, :qty]
puts r.send(names[1])
setters = [:price=, :qty=]
r.send(setters[0], 11)
puts r.price
