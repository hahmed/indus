# a text-adventure state machine: symbols, case/in-less dispatch, hash of lambdas, loops with next/break
class Game
  attr_reader :log
  def initialize
    @room = :hall
    @inventory = []
    @log = []
    @rooms = {
      hall: { desc: "a dusty hall", exits: { north: :library, east: :kitchen } },
      library: { desc: "shelves of books", exits: { south: :hall }, item: :key },
      kitchen: { desc: "a cold kitchen", exits: { west: :hall, down: :cellar } },
      cellar: { desc: "the locked cellar", exits: { up: :kitchen }, locked: true },
    }
    @commands = {
      "look" => ->(_) { say(@rooms[@room][:desc]) },
      "take" => ->(_) { take },
      "inv" => ->(_) { say(@inventory.empty? ? "nothing" : @inventory.map(&:to_s).sort.join(", ")) },
    }
  end
  def say(msg) = @log << msg
  def take
    item = @rooms[@room][:item]
    if item
      @inventory << item
      @rooms[@room].delete(:item)
      say("took #{item}")
    else
      say("nothing here")
    end
  end
  def go(dir)
    dest = @rooms[@room][:exits][dir]
    return say("you can't go #{dir}") unless dest
    if @rooms[dest][:locked] && !@inventory.include?(:key)
      return say("the #{dest} is locked")
    end
    @room = dest
    say("you are in #{@rooms[dest][:desc]}")
  end
  def run(script)
    script.each do |line|
      verb, arg = line.split(" ", 2)
      next if verb.nil?
      break if verb == "quit"
      if (cmd = @commands[verb])
        cmd.call(arg)
      elsif verb == "go"
        go(arg.to_sym)
      else
        say("unknown: #{verb}")
      end
    end
    self
  end
end
g = Game.new.run(["look", "go east", "go down", "go west", "go north", "take", "take", "inv", "go south", "go east", "go down", "dance", "", "quit", "look"])
puts g.log
puts g.log.size
