# a vending machine state machine: symbols, send, hash of transitions, guards
class Machine
  attr_reader :state, :log
  TRANSITIONS = {
    idle: { coin: :has_coin, refund: :idle },
    has_coin: { coin: :has_coin, select: :dispensing, refund: :idle },
    dispensing: { done: :idle },
  }
  def initialize
    @state = :idle
    @credit = 0
    @log = []
  end
  def fire(event, amount = 0)
    table = TRANSITIONS[@state]
    nxt = table[event]
    if nxt.nil?
      @log << "ignored #{event} in #{@state}"
      return false
    end
    before = @state
    @state = nxt
    send("on_#{event}", amount) if respond_to?("on_#{event}")
    @log << "#{before} -#{event}-> #{@state}"
    true
  end
  def on_coin(amount) = @credit += amount
  def on_refund(_) = @credit = 0
  def on_select(_)
    @credit -= 50
    fire(:done)
  end
  def credit = @credit
end

m = Machine.new
puts m.fire(:select)
m.fire(:coin, 25)
m.fire(:coin, 50)
puts m.credit
m.fire(:select)
puts m.state, m.credit
m.fire(:coin, 10)
m.fire(:refund)
puts m.credit, m.state
puts m.log.length
m.log.each { |l| puts "  #{l}" }
