define_method(:zero) { 0 }
define_method(:one) { |arg| arg }
define_method(:add2) { |a, b| a + b }
puts zero
puts one(7)
puts add2(3, 4)
