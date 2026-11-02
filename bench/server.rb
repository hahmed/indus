# a long-running loop that keeps 1 in 500 of what it makes: tier 1 cannot
# reset here (stores into a pre-existing array), so this needs a collector
class Request
  attr_reader :id, :path, :params
  def initialize(id)
    @id = id
    @path = "/items/" + id.to_s
    @params = Array.new(4, 0)
    @params[0] = id
    @params[1] = id * 2
  end
  def checksum
    @path.length + @params[0] + @params[1]
  end
end

kept = []
total = 0
i = 0
while i < 400000
  r = Request.new(i)
  total = total + r.checksum
  kept.push(r) if i % 500 == 0
  i = i + 1
end
puts total
puts kept.length
s = 0
kept.each { |r| s = s + r.checksum }
puts s
puts kept[300].path
