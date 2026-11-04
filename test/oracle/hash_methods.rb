h = { "a" => 1, "b" => 2 }
h.each_pair { |k, v| puts k + "=" + v.to_s }
h = { "a" => 3, "b" => 1 }
h.sort_by { |k, v| v }.each { |k, v| puts k + v.to_s }
h = { "a" => 3, "b" => 1 }
puts h.map { |k, v| k + v.to_s }.inspect
h = { "a" => 3 }
puts h.values.inspect
puts h.key?("a")
puts h.fetch("a")
puts h.size
puts h.has_key?("z")
puts h.length
h = { a: 1, b: 2 }
puts h[:a]
puts h.keys.inspect
h.each { |k, v| puts k.to_s + "=" + v.to_s }
h = Hash.new(0)
h["x"] += 1
puts h["x"]
puts h["y"]
