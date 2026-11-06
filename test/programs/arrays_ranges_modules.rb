a = (1..5).to_a
puts a.length
puts a[0] + a[4]
puts a.shift
puts a.length
puts a[0]
a.reverse!
puts a[0]
puts a[3]
b = (0...3).to_a
puts b.length
module Counter
  @count = 10
  def self.bump
    @count = @count + 1
    @count
  end
end
puts Counter.bump
puts Counter.bump
