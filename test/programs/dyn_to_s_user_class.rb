class A; def to_s = "A!"; end
xs = [A.new, 1, "s", nil, 2.5]
xs.each { |x| puts x.to_s; puts "#{x}" }
puts xs.map(&:to_s).join(",")
