class S
  def initialize = @t = []
  def it(name, &b) = @t << [name, b]
  def run
    @t.each do |(nm, b)|
      b.call
    end
  end
end
s = S.new
s.it("a") { puts "one" }
s.it("b") { puts "two" }
s.run
