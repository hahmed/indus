class Rec
  attr_reader :a, :b
  def self.create(**attrs) = new.tap { |o| attrs.each { |k, v| o.instance_variable_set("@#{k}", v) } }
  def initialize(**o) = o.each { |k, v| instance_variable_set(:"@#{k}", v) }
  def [](k) = instance_variable_get(:"@#{k}")
  def ivars = instance_variables.map { |iv| [iv, instance_variable_get(iv)] }.to_h
  def has?(k) = instance_variable_defined?("@#{k}")
end
o = Rec.create(a: 1, b: "two")
p o.a, o.b, o[:a], o[:b], o.ivars, o.has?(:a), o.has?(:zz)
r = Rec.new(b: 5)
p r.a, r.b, r.ivars
p({:@a => 1, :"x y" => 2, :a? => 3, :c= => 5, :+ => 6, :A => 7, :ok => 8})
r = Rec.new(b: 5)
r.instance_variable_set(:@fresh, 9); p r.instance_variable_get(:@fresh), r.ivars
