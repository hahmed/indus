# a tiny physics step with Struct, Comparable, each_slice, formatting, frozen constants
Vec = Struct.new(:x, :y) do
  def +(o) = Vec.new(x + o.x, y + o.y)
  def *(k) = Vec.new(x * k, y * k)
  def length = Math.sqrt(x * x + y * y)
  def to_s = format("(%.2f, %.2f)", x, y)
end
class Body
  include Comparable
  attr_accessor :pos, :vel, :mass
  def initialize(pos, vel, mass) = (@pos, @vel, @mass = pos, vel, mass)
  def <=>(other) = mass <=> other.mass
  def step(dt, g)
    @vel = @vel + g * dt
    @pos = @pos + @vel * dt
    self
  end
  def energy = 0.5 * mass * vel.length**2
end
G = Vec.new(0.0, -9.8).freeze
bodies = [Body.new(Vec.new(0.0, 10.0), Vec.new(1.0, 0.0), 2.0), Body.new(Vec.new(5.0, 20.0), Vec.new(-1.0, 2.0), 1.0), Body.new(Vec.new(1.0, 1.0), Vec.new(0.0, 0.0), 3.5)]
10.times { bodies.each { |b| b.step(0.1, G) } }
bodies.sort.each { |b| puts "#{b.mass}: #{b.pos} v=#{b.vel} E=#{'%.3f' % b.energy}" }
puts bodies.max.mass, bodies.min.mass
puts bodies.map(&:energy).sum.round(3)
puts (1..10).each_slice(3).map(&:sum).inspect
puts bodies.minmax.map(&:mass).inspect
puts bodies.sort { |a, b| b.pos.y <=> a.pos.y }.map { |b| b.mass }.inspect rescue puts "sort-block unsupported"
heavy, light = bodies.partition { |b| b.mass > 1.5 }
puts heavy.size, light.size
puts bodies.first.clamp(bodies.min, bodies.max).mass
