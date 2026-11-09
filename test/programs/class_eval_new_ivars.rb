class Counter
  def initialize(name) = @name = name
  def report = "#{@name}: plain"
end
cs = 3.times.map { |i| Counter.new("c#{i}") }
puts cs.map(&:report)
code = <<~'RUBY'
  def report
    @hits ||= 0
    @hits += 1
    @log ||= []
    @log << @hits
    "#{@name}: #{@hits} hits, log #{@log.inspect}"
  end
RUBY
Counter.class_eval code
puts cs.map(&:report)
GC.start
puts cs.map(&:report)
