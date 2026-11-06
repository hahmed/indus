# bank/ledger with modules, custom errors, keyword args, and money formatting
module Auditable
  def audit(event, detail = nil)
    (@audit_log ||= []) << (detail ? "#{event}: #{detail}" : event)
    self
  end
  def audit_log = @audit_log || []
end
class InsufficientFunds < StandardError
  attr_reader :short
  def initialize(short)
    super("short by #{Account.money(short)}")
    @short = short
  end
end
class Account
  include Auditable
  include Comparable
  attr_reader :owner, :cents
  def self.money(cents) = format("$%.2f", cents / 100.0)
  def initialize(owner, cents: 0)
    @owner = owner
    @cents = cents
    audit("open", owner)
  end
  def deposit(amount)
    raise ArgumentError, "non-positive" unless amount > 0
    @cents += amount
    audit("deposit", Account.money(amount))
  end
  def withdraw(amount)
    raise InsufficientFunds.new(amount - @cents) if amount > @cents
    @cents -= amount
    audit("withdraw", Account.money(amount))
  end
  def transfer_to(other, amount)
    withdraw(amount)
    other.deposit(amount)
    audit("transfer", "#{Account.money(amount)} to #{other.owner}")
  end
  def <=>(other) = cents <=> other.cents
  def to_s = "#{owner}: #{Account.money(cents)}"
end

a = Account.new("ann", cents: 10_000)
b = Account.new("bob")
a.deposit(2_500)
a.transfer_to(b, 3_000)
begin
  b.withdraw(99_999)
rescue InsufficientFunds => e
  puts "error: #{e.message} (#{e.short})"
end
begin
  a.deposit(-1)
rescue ArgumentError => e
  puts "error: #{e.message}"
end
puts a, b
puts [a, b].max.owner
puts a > b
puts a.audit_log.length
a.audit_log.each { |l| puts "  #{l}" }
puts b.audit_log.inspect
