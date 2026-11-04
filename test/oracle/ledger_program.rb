# a tiny bank ledger
class Account
  attr_reader :name, :balance, :history
  def initialize(name, balance = 0)
    @name = name
    @balance = balance
    @history = []
  end
  def deposit(amount)
    raise ArgumentError, "amount must be positive" if amount <= 0
    @balance += amount
    @history << [:deposit, amount]
    self
  end
  def withdraw(amount)
    raise "insufficient funds" if amount > @balance
    @balance -= amount
    @history << [:withdraw, amount]
    self
  end
  def to_s = "#{name}: #{balance}"
end
accounts = [Account.new("ann", 100), Account.new("bob")]
accounts[0].deposit(50).withdraw(30)
accounts[1].deposit(10)
begin
  accounts[1].withdraw(500)
rescue => e
  puts "error: #{e.message}"
end
accounts.each { |a| puts a }
total = accounts.sum { |a| a.balance }
puts "total: #{total}"
richest = accounts.max_by(&:balance)
puts richest.name
puts accounts.map(&:to_s).join("; ")
kinds = accounts.flat_map(&:history).map(&:first).tally
puts kinds.inspect
puts accounts.first.history.length
puts accounts.any? { |a| a.balance > 100 }
puts accounts.all? { |a| a.balance > 5 }
puts accounts.find { |a| a.name == "bob" }.balance
