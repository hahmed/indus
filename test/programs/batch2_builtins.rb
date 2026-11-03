p 42
p "hi"
p -3
p nil
p true
x = "a" + "b"
p x
print "no newline"
print 7
print "\n"
n = Integer(ARGV[0] || 10)
puts n
m = (ARGV[1] || 3).to_i
puts m
a = Array.new(5) { |i| i * i }
puts a[3]
puts a.length
b = Array.new(3) { "s" }
puts b[2]
class Node
  attr_accessor :left
  def initialize
    @left = nil
  end
end
node = Node.new
puts node.left.nil?
node.left = Node.new
puts node.left.nil?
puts nil.nil?
puts 5.nil?
