def r(n) = Math.sqrt(n)
puts [4, 9].map { |n| r(n) }.inspect
puts [4.0, 9.0].map { |n| Math.sqrt(n) }.inspect
puts [4, 9].map { |n| n * 1.5 }.inspect
