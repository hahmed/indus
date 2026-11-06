require_relative "multi/bank"
require_relative "multi/account"
require "set"
a = Bank.open(10)
a.deposit(5)
puts a.balance
seen = Set.new
[1, 2, 2, 3].each { |x| seen << x }
puts seen.size
puts seen.to_a.sort.inspect
