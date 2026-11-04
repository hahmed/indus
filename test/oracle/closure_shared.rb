count = 0
bump = -> { count += 1 }
bump.call
bump.call
puts count
count = 10
bump.call
puts count
def counter
  n = 0
  inc = -> { n += 1; n }
  inc.call
  inc.call
  inc
end
c = counter
puts c.call
puts c.call
acc = []
adder = ->(x) { acc.push(x) }
adder.call(3)
adder.call(4)
puts acc.inspect
name = "a"
greet = -> { "hi " + name }
name = "b"
puts greet.call
total = 0
[1, 2, 3].each { |v| total += v }
puts total
