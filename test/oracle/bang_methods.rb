xs = [3, 1, 2]
xs.sort!
puts xs.inspect
xs.map! { |x| x * 10 }
puts xs.inspect
xs.reverse!
puts xs.inspect
xs.select! { |x| x > 10 }
puts xs.inspect
