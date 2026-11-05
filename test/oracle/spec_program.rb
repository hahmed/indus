# a tiny test framework: blocks stored and run later, exceptions, counters
class Spec
  def initialize = (@tests = []; @pass = 0; @fail = 0; @messages = [])
  def it(name, &blk) = @tests << [name, blk]
  def run
    @tests.each do |(name, blk)|
      begin
        blk.call
        @pass += 1
      rescue RuntimeError => e
        @fail += 1
        @messages << "#{name}: #{e.message}"
      end
    end
    self
  end
  def assert(cond, msg = "assertion failed") = (raise msg unless cond)
  def assert_equal(a, b) = assert(a == b, "expected #{b.inspect}, got #{a.inspect}")
  def report
    puts "#{@pass} passed, #{@fail} failed"
    @messages.each { |m| puts "  #{m}" }
  end
end

s = Spec.new
s.it("adds") { s.assert_equal(1 + 1, 2) }
s.it("subtracts") { s.assert_equal(5 - 2, 4) }
s.it("strings") { s.assert_equal("ab" + "c", "abc") }
s.it("arrays") { s.assert([1, 2].include?(3)) }
s.it("raises") { raise "boom" }
s.run.report
