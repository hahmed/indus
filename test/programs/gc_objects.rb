class Req
  attr_reader :id, :path, :params
  def initialize(id)
    @id = id
    @path = "x"
    @params = Array.new(4, 0)
    @params[0] = id
  end
  def checksum
    @path.length + @params[0]
  end
end
kept = []
total = 0
i = 0
while i < 100000
  r = Req.new(i)
  total = total + r.checksum
  kept.push(r) if i % 25000 == 0
  i = i + 1
end
puts total
puts kept[2].path
