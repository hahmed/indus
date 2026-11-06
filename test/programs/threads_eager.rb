threads = (0...3).map do |t|
  Thread.new(t) do |tid|
    s = 0
    i = 0
    while i < 1000
      s = s + tid * i
      Thread.pass if i % 100 == 0
      i = i + 1
    end
    [s, tid]
  end
end
total = 0
threads.each_with_index do |th, i|
  v, tid = th.value
  total = total + v
  puts "thread #{i}: #{v} #{tid}"
end
puts total
