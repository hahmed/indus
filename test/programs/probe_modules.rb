module Greet
  DEFAULT = "hi"
  def greet(name = nil) = "#{self.class::PREFIX} #{name || DEFAULT} from #{self.class.name}"
  def self.version = "1.0"
end
module Loud
  def greet(name = nil) = super.upcase + "!"
end
class Base
  PREFIX = ">"
  include Greet
  @@count = 0
  @registry = []
  class << self
    attr_accessor :registry
    def create(*args) = (@@count += 1; new(*args).tap { |o| registry << o })
    def count = @@count
  end
  def initialize(n = 0) = @n = n
  attr_reader :n
  protected :n
  def bigger?(o) = n > o.n
  private
  def secret = "s"
  public
  def reveal = secret
end
class Child < Base
  PREFIX = ">>"
  include Loud
  def initialize(n) = super
end
puts Base.new.greet, Child.new(1).greet("bob"), Greet.version, Greet::DEFAULT
Base.create(1); Base.create(2)
puts Base.count, Base.registry.size
puts Child.new(5).bigger?(Base.new(2)), Base.new.reveal
puts Base.new.respond_to?(:greet), Base.new.respond_to?(:secret), Child.new(1).is_a?(Greet), Greet === Child.new(1)
puts Child.name, Child.to_s, Child.class, Base.new.frozen?
