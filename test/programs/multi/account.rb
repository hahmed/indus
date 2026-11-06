class Account
  attr_reader :balance
  def initialize(b) = @balance = b
  def deposit(n) = @balance += n
end
