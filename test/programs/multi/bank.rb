require_relative "account"
module Bank
  def self.open(n) = Account.new(n)
end
